defmodule McFunWeb.WebhookController do
  @moduledoc """
  JSON API controller for incoming webhooks.

  Accepts POST requests at `/api/webhooks/:action` and triggers
  in-game effects or dispatches events.

  ## Actions

  - `announce` — broadcast a message in-game (`message` param)
  - `celebrate` — trigger celebration effects (`player` param)
  - `firework` — launch firework (`player`, `colors`, `shape` params)
  - `title` — display title text (`player`, `text`, `subtitle` params)
  - `github_push` — handle GitHub push webhook
  """
  use McFunWeb, :controller

  require Logger

  @valid_name_pattern ~r/^[@\w]+$/

  def handle(conn, %{"action" => action} = params) do
    case process_webhook(action, params) do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: to_string(reason)})
    end
  end

  def handle(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing action"})
  end

  # --- Webhook actions ---

  defp process_webhook("announce", %{"message" => message}) when byte_size(message) <= 256 do
    McFun.Rcon.command("say #{sanitize_text(message)}")
    :ok
  end

  defp process_webhook("announce", _), do: {:error, "missing or oversized message"}

  defp process_webhook("celebrate", %{"player" => player}) do
    with :ok <- validate_target(player) do
      Task.start(fn -> McFun.Effects.celebration(player) end)
      :ok
    end
  end

  defp process_webhook("celebrate", _), do: {:error, "missing player"}

  defp process_webhook("firework", params) do
    player = Map.get(params, "player", "@a")

    with :ok <- validate_target(player) do
      opts = parse_firework_opts(params)
      Task.start(fn -> McFun.Effects.firework(player, opts) end)
      :ok
    end
  end

  defp process_webhook("title", %{"player" => player, "text" => text} = params) do
    with :ok <- validate_target(player) do
      opts =
        []
        |> maybe_put(:subtitle, Map.get(params, "subtitle"))
        |> maybe_put(:fade_in, parse_int(Map.get(params, "fade_in")))
        |> maybe_put(:stay, parse_int(Map.get(params, "stay")))
        |> maybe_put(:fade_out, parse_int(Map.get(params, "fade_out")))

      Task.start(fn -> McFun.Effects.title(player, sanitize_text(text), opts) end)
      :ok
    end
  end

  defp process_webhook("title", _), do: {:error, "missing player or text"}

  defp process_webhook("github_push", %{"pusher" => %{"name" => name}}) do
    safe_name = sanitize_text(name)
    McFun.Events.dispatch(:webhook_received, %{source: :github, pusher: safe_name, action: :push})
    McFun.Rcon.command("say [GitHub] #{safe_name} pushed new code!")
    Task.start(fn -> McFun.Effects.celebration("@a") end)
    :ok
  end

  defp process_webhook("github_push", _), do: {:error, "invalid github payload"}

  defp process_webhook(action, _), do: {:error, "unknown action: #{action}"}

  # --- Helpers ---

  defp validate_target(target) do
    if Regex.match?(@valid_name_pattern, target), do: :ok, else: {:error, "invalid target name"}
  end

  defp sanitize_text(text) do
    text
    |> String.replace(~r/[^\w\s.,!?@#\-:;'"]/, "")
    |> String.slice(0, 256)
  end

  defp parse_firework_opts(params) do
    opts = []
    opts = if colors = Map.get(params, "colors"), do: [{:colors, List.wrap(colors)} | opts], else: opts
    opts = if shape = Map.get(params, "shape"), do: [{:shape, shape} | opts], else: opts
    opts = if flight = parse_int(Map.get(params, "flight")), do: [{:flight, flight} | opts], else: opts
    opts
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: [{key, val} | opts]
end
