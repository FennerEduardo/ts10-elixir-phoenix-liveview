defmodule TransactionalSystemElixirPhoenix.Runtime.Telemetry do
  @moduledoc """
  W3C trace-context helpers. Spans go to the configured OpenTelemetry SDK
  (exporters are configured with the OTEL_* variables or the :opentelemetry app env).
  """

  def tracer, do: :opentelemetry.get_tracer(:transactional_system_elixir_phoenix)

  @doc "Context whose parent is the span described by an incoming traceparent header."
  def context_from(nil), do: :otel_ctx.new()
  def context_from(""), do: :otel_ctx.new()

  def context_from(traceparent) do
    :otel_propagator_text_map.extract_to(:otel_ctx.new(), :otel_propagator_trace_context, [{"traceparent", traceparent}])
  end

  @doc "Starts a span (kind: :internal | :producer | :consumer) under a parent context; returns {span_ctx, ctx_with_span}."
  def start_span(parent_ctx, name, kind, attributes) do
    span_ctx = :otel_tracer.start_span(parent_ctx, tracer(), name, %{kind: kind, attributes: attributes})
    {span_ctx, :otel_tracer.set_current_span(parent_ctx, span_ctx)}
  end

  @doc "traceparent header value for a context (nil when it carries no valid span)."
  def traceparent_of(ctx) do
    ctx
    |> :otel_propagator_text_map.inject_from(:otel_propagator_trace_context, [])
    |> List.keyfind("traceparent", 0)
    |> case do
      {_, value} -> value
      nil -> nil
    end
  end

  def error(span_ctx, exception) do
    :otel_span.set_status(span_ctx, :opentelemetry.status(:error, Exception.message(exception)))
  end
end
