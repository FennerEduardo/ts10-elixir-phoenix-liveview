defmodule TransactionalSystemElixirPhoenix.JwtTenant do
  @moduledoc """
  HS256 bearer tokens. The tenant comes only from the "tenant_id" claim of a validated token, never from a
  header such as X-Tenant-Id, and there is no default tenant.
  """

  @tenant_claim "tenant_id"
  def tenant_claim, do: @tenant_claim

  @doc "Tenant claim of a valid token (signature, exp, nbf checked), else nil."
  def tenant_from(authorization, secret \\ System.get_env("JWT_SECRET", ""))

  def tenant_from("Bearer " <> token, secret) when is_binary(secret) and secret != "" do
    with [head, body, sig] <- String.split(String.trim(token), "."),
         {:ok, %{"alg" => "HS256"}} <- decode_json(head),
         {:ok, given} <- Base.url_decode64(sig, padding: false),
         true <- Plug.Crypto.secure_compare(given, :crypto.mac(:hmac, :sha256, secret, head <> "." <> body)),
         {:ok, claims} when is_map(claims) <- decode_json(body),
         true <- valid_time?(claims),
         tenant when is_binary(tenant) <- claims[@tenant_claim],
         false <- String.trim(tenant) == "" do
      tenant
    else
      _ -> nil
    end
  end

  def tenant_from(_authorization, _secret), do: nil

  @doc "Signs an HS256 token (tests and local tooling; production tokens come from your identity provider)."
  def sign(claims, secret) do
    head = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
    body = Base.url_encode64(Jason.encode!(claims), padding: false)
    head <> "." <> body <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, head <> "." <> body), padding: false)
  end

  defp decode_json(part) do
    with {:ok, raw} <- Base.url_decode64(part, padding: false), do: Jason.decode(raw)
  end

  defp valid_time?(claims) do
    now = System.os_time(:second)
    not ((is_number(claims["exp"]) and now >= claims["exp"]) or (is_number(claims["nbf"]) and now < claims["nbf"]))
  end
end
