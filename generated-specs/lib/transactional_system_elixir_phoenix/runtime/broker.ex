defmodule TransactionalSystemElixirPhoenix.Runtime.Broker do
  @moduledoc """
  The event broker behind the outbox relay and the inbox consumer, chosen at run time so one image runs on any
  cloud: GHK_BROKER=rabbitmq (AMQP_URL) or pubsub (PUBSUB_PROJECT_ID or GOOGLE_CLOUD_PROJECT; PUBSUB_EMULATOR_HOST).
  Without GHK_BROKER the configured variables decide, then stack.messaging.
  Azure Service Bus has no official Elixir SDK: on Azure use self-managed RabbitMQ or CloudAMQP (AMQP_URL).

  Messages are maps: %{message_id, event_type, tenant_id, traceparent, body}. poll/1 returns nil or
  %{message: message, ack: fun, dead_letter: fun}; dead_letter moves the message to the DLQ (it is not redelivered).
  """

  @default_kind "rabbitmq"
  @metadata_token ~c"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

  defp env(key) do
    case System.get_env(key) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end
  end

  def kind do
    cond do
      env("GHK_BROKER") -> env("GHK_BROKER") |> String.trim() |> String.downcase()
      env("AMQP_URL") -> "rabbitmq"
      env("PUBSUB_PROJECT_ID") || env("PUBSUB_EMULATOR_HOST") -> "pubsub"
      true -> @default_kind
    end
  end

  @doc "Whether the variables of the selected broker are set."
  def configured? do
    if kind() == "pubsub", do: (env("PUBSUB_PROJECT_ID") || env("GOOGLE_CLOUD_PROJECT")) != nil, else: env("AMQP_URL") != nil
  end

  def connect do
    case kind() do
      "rabbitmq" ->
        url = env("AMQP_URL") || raise "AMQP_URL is not set (amqp://user:password@host:5672)"
        {:ok, connection} = AMQP.Connection.open(url)
        %{type: :rabbitmq, connection: connection}

      "pubsub" ->
        {:ok, _} = Application.ensure_all_started([:inets, :ssl])
        project = env("PUBSUB_PROJECT_ID") || env("GOOGLE_CLOUD_PROJECT") || raise "PUBSUB_PROJECT_ID (or GOOGLE_CLOUD_PROJECT) is not set"
        host = env("PUBSUB_EMULATOR_HOST")
        base = if host, do: "http://#{host}", else: "https://pubsub.googleapis.com"
        %{type: :pubsub, project: project, root: "#{base}/v1/projects/#{project}", emulator: host != nil}

      "servicebus" ->
        raise "Azure Service Bus has no official Elixir SDK: use RabbitMQ (self-managed or CloudAMQP) on Azure"

      other ->
        raise "Unsupported GHK_BROKER: #{other} (rabbitmq, pubsub)"
    end
  end

  def system(%{type: :rabbitmq}), do: "rabbitmq"
  def system(%{type: :pubsub}), do: "gcp_pubsub"

  def close(%{type: :rabbitmq, connection: connection}), do: AMQP.Connection.close(connection)
  def close(_broker), do: :ok

  @doc "Creates the topology if missing (idempotent); in production it usually comes from infrastructure as code."
  def declare(%{type: :rabbitmq, connection: connection}, t) do
    {:ok, chan} = AMQP.Channel.open(connection)
    :ok = AMQP.Exchange.declare(chan, t.exchange, :topic, durable: true)
    :ok = AMQP.Exchange.declare(chan, t.dlx, :fanout, durable: true)
    {:ok, _} = AMQP.Queue.declare(chan, t.dlq, durable: true)
    :ok = AMQP.Queue.bind(chan, t.dlq, t.dlx)
    {:ok, _} = AMQP.Queue.declare(chan, t.queue, durable: true, arguments: [{"x-dead-letter-exchange", :longstr, t.dlx}])
    :ok = AMQP.Queue.bind(chan, t.queue, t.exchange, routing_key: "#")
    AMQP.Channel.close(chan)
    :ok
  end

  def declare(%{type: :pubsub, project: project} = b, t) do
    # 409: it already exists (created earlier or by infrastructure as code).
    call(b, :put, "/topics/#{t.exchange}", %{}, [409])
    call(b, :put, "/topics/#{t.dlx}", %{}, [409])
    call(b, :put, "/subscriptions/#{t.queue}", %{topic: "projects/#{project}/topics/#{t.exchange}", ackDeadlineSeconds: 60}, [409])
    call(b, :put, "/subscriptions/#{t.dlq}", %{topic: "projects/#{project}/topics/#{t.dlx}", ackDeadlineSeconds: 60}, [409])
    :ok
  end

  @doc "A publisher for one destination; publish/2 returns only once the broker has durably accepted the message."
  def publisher(%{type: :rabbitmq, connection: connection}, exchange) do
    {:ok, chan} = AMQP.Channel.open(connection)
    :ok = AMQP.Confirm.select(chan)
    %{type: :rabbitmq, chan: chan, destination: exchange}
  end

  def publisher(%{type: :pubsub} = b, topic), do: %{type: :pubsub, broker: b, destination: topic}

  def publish(%{type: :rabbitmq, chan: chan, destination: exchange}, m) do
    headers =
      [{"tenant_id", m.tenant_id}, {"traceparent", m.traceparent}]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, :longstr, v} end)

    :ok = AMQP.Basic.publish(chan, exchange, m.event_type || "", m.body, message_id: m.message_id, persistent: true, content_type: "application/json", type: m.event_type, headers: headers)
    true = AMQP.Confirm.wait_for_confirms(chan, 10_000)
    :ok
  end

  def publish(%{type: :pubsub, broker: b, destination: topic}, m), do: publish_to(b, topic, m)

  def close_publisher(%{type: :rabbitmq, chan: chan}), do: AMQP.Channel.close(chan)
  def close_publisher(_publisher), do: :ok

  @doc "A subscription on a queue / pull subscription; t says where dead-lettered messages go."
  def subscribe(%{type: :rabbitmq, connection: connection}, queue, _t) do
    {:ok, chan} = AMQP.Channel.open(connection)
    %{type: :rabbitmq, chan: chan, source: queue}
  end

  def subscribe(%{type: :pubsub} = b, subscription, t), do: %{type: :pubsub, broker: b, source: subscription, dlx: t.dlx}

  def close_subscription(%{type: :rabbitmq, chan: chan}), do: AMQP.Channel.close(chan)
  def close_subscription(_subscription), do: :ok

  @doc "The next waiting message, or nil."
  def poll(%{type: :rabbitmq, chan: chan, source: queue}) do
    case AMQP.Basic.get(chan, queue, no_ack: false) do
      {:ok, body, meta} ->
        message = %{message_id: to_string(meta.message_id), event_type: meta.type, tenant_id: header(meta, "tenant_id"), traceparent: header(meta, "traceparent"), body: body}
        # Rejected without requeue: RabbitMQ dead-letters it through the queue's DLX.
        %{message: message, ack: fn -> AMQP.Basic.ack(chan, meta.delivery_tag) end, dead_letter: fn -> AMQP.Basic.reject(chan, meta.delivery_tag, requeue: false) end}

      {:empty, _} ->
        nil
    end
  end

  def poll(%{type: :pubsub, broker: b, source: subscription, dlx: dlx}) do
    case call(b, :post, "/subscriptions/#{subscription}:pull", %{maxMessages: 1, returnImmediately: true}) do
      %{"receivedMessages" => [first | _]} ->
        msg = first["message"]
        attrs = msg["attributes"] || %{}

        message = %{
          message_id: attrs["ghk_message_id"] || msg["messageId"],
          event_type: attrs["event_type"],
          tenant_id: attrs["tenant_id"],
          traceparent: attrs["traceparent"],
          body: Base.decode64!(msg["data"] || "")
        }

        ack = fn -> call(b, :post, "/subscriptions/#{subscription}:acknowledge", %{ackIds: [first["ackId"]]}) end

        %{message: message, ack: ack, dead_letter: fn ->
          publish_to(b, dlx, message)
          ack.()
        end}

      _ ->
        nil
    end
  end

  defp header(meta, name) do
    headers = if is_list(meta.headers), do: meta.headers, else: []

    case List.keyfind(headers, name, 0) do
      {_, _, value} -> value
      _ -> nil
    end
  end

  defp publish_to(b, topic, m) do
    attributes =
      %{"ghk_message_id" => m.message_id, "event_type" => m.event_type, "tenant_id" => m.tenant_id, "traceparent" => m.traceparent}
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    case call(b, :post, "/topics/#{topic}:publish", %{messages: [%{data: Base.encode64(m.body), attributes: attributes}]}) do
      %{"messageIds" => [_]} -> :ok
      other -> raise "Pub/Sub did not accept message #{m.message_id}: #{inspect(other)}"
    end
  end

  # Calls the API; a status listed in accepted returns nil instead of failing.
  defp call(b, method, path, body, accepted \\ []) do
    headers = Enum.map(List.wrap(bearer(b)), &{~c"authorization", String.to_charlist("Bearer " <> &1)})
    request = {String.to_charlist(b.root <> path), headers, ~c"application/json", Jason.encode!(body)}
    http_opts = [timeout: 30_000] ++ if(b.emulator, do: [], else: [ssl: ssl_opts()])

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response}} when status in 200..299 -> if response == "", do: %{}, else: Jason.decode!(response)
      {:ok, {{_, status, _}, _headers, response}} -> if status in accepted, do: nil, else: raise("Pub/Sub #{method} #{path} failed: #{status} #{response}")
      {:error, reason} -> raise "Pub/Sub #{method} #{path} failed: #{inspect(reason)}"
    end
  end

  defp ssl_opts, do: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]

  defp bearer(%{emulator: true}), do: nil

  defp bearer(_b) do
    case env("GOOGLE_OAUTH_ACCESS_TOKEN") do
      nil ->
        case :persistent_term.get({__MODULE__, :token}, nil) do
          {token, expires} when expires > 0 -> if System.system_time(:second) < expires, do: token, else: fetch_token()
          _ -> fetch_token()
        end

      token ->
        token
    end
  end

  defp fetch_token do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {@metadata_token, [{~c"metadata-flavor", ~c"Google"}]}, [timeout: 5_000], body_format: :binary)
    %{"access_token" => token, "expires_in" => expires_in} = Jason.decode!(body)
    :persistent_term.put({__MODULE__, :token}, {token, System.system_time(:second) + expires_in - 60})
    token
  end
end
