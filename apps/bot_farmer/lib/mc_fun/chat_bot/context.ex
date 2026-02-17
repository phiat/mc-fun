defmodule McFun.ChatBot.Context do
  @moduledoc """
  Builds environment context strings for ChatBot LLM prompts.

  Fetches bot survey data, formats position/inventory/entities/vitals,
  and assembles the full context block used in system prompts.
  """

  @recent_chat_limit 10

  @doc """
  Build environment context string for an LLM prompt.

  Returns a combined string with survey data, bot status, and optional chat history.

  ## Options

    * `:history` - conversation history list of `{:player, msg}` / `{:bot, msg}` tuples
  """
  def build(bot_name, opts \\ []) do
    survey_context = fetch_survey(bot_name)
    bot_status = format_bot_status(bot_name)
    chat_history = format_recent_chat(Keyword.get(opts, :history, []))

    survey_context <> bot_status <> chat_history
  end

  @doc "Fetch and format survey data from the bot's bridge. Returns empty string on failure."
  def fetch_survey(bot_name) do
    case McFun.Bot.survey(bot_name) do
      {:ok, survey} -> format_survey(survey)
      _ -> ""
    end
  catch
    _, _ -> ""
  end

  @doc "Format raw survey map into a human-readable environment block."
  def format_survey(s) do
    [
      "\n[ENVIRONMENT]",
      format_position(s["position"]),
      format_looking_at(s["looking_at"]),
      format_block_list(s["blocks"]),
      format_inventory(s["inventory"]),
      format_entities(s["entities"]),
      format_vitals(s["health"], s["food"])
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc "Format bot's current action and behavior into a status block."
  def format_bot_status(bot_name) do
    action_str =
      case McFun.Bot.current_action(bot_name) do
        %{action: action, source: source, started_at: started_at} ->
          elapsed = DateTime.diff(DateTime.utc_now(), started_at, :second)
          "Current action: #{action} (#{source}-initiated, started #{elapsed}s ago)"

        nil ->
          "Current action: idle"
      end

    behavior_str =
      case McFun.BotBehaviors.info(bot_name) do
        %{behavior: behavior} ->
          paused =
            case McFun.Bot.current_action(bot_name) do
              %{source: :tool} -> " (paused - tool action in progress)"
              _ -> ""
            end

          "Active behavior: #{behavior}#{paused}"

        _ ->
          "Active behavior: none"
      end

    "\n[BOT STATUS]\n#{action_str}\n#{behavior_str}"
  end

  @doc "Format recent conversation history into a chat block."
  def format_recent_chat(history) do
    entries =
      history
      |> Enum.take(@recent_chat_limit)
      |> Enum.reverse()
      |> Enum.map(fn
        {:player, msg} -> "Player: #{msg}"
        {:bot, msg} -> "Bot: #{msg}"
      end)

    case entries do
      [] -> ""
      lines -> "\n[RECENT CHAT]\n" <> Enum.join(lines, "\n")
    end
  end

  # Private formatters

  defp format_position(%{"x" => x, "y" => y, "z" => z}), do: "Position: #{x}, #{y}, #{z}"
  defp format_position(_), do: []

  defp format_looking_at(nil), do: []
  defp format_looking_at(block), do: "Looking at: #{block}"

  defp format_block_list(list) when is_list(list) and list != [],
    do: "Nearby blocks: #{Enum.join(list, ", ")}"

  defp format_block_list(_), do: []

  defp format_inventory(list) when is_list(list) and list != [] do
    inv = Enum.map_join(list, ", ", fn i -> "#{i["name"]}x#{i["count"]}" end)
    "Inventory: #{inv}"
  end

  defp format_inventory(_), do: []

  defp format_entities(list) when is_list(list) and list != [] do
    ents = Enum.map_join(list, ", ", fn e -> "#{e["name"]}(#{e["distance"]}m)" end)
    "Nearby entities: #{ents}"
  end

  defp format_entities(_), do: []

  defp format_vitals(nil, _), do: []
  defp format_vitals(health, food), do: "Health: #{trunc(health)}/20, Food: #{food}/20"
end
