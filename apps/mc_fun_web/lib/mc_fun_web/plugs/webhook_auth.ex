defmodule McFunWeb.Plugs.WebhookAuth do
  @moduledoc """
  Plug that authenticates webhook requests via Bearer token.

  If WEBHOOK_SECRET is not configured, all requests are allowed (dev convenience).
  When configured, requests must include `Authorization: Bearer <token>`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:mc_fun, :webhook_secret) do
      nil ->
        # No secret configured — allow all (dev mode)
        conn

      "" ->
        conn

      expected_token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] when token == expected_token ->
            conn

          _ ->
            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{error: "unauthorized"})
            |> halt()
        end
    end
  end
end
