defmodule McFun.ActionParser do
  @moduledoc """
  Parses LLM response text to extract bot action intents.

  Uses regex pattern matching (no LLM call) to detect when the bot's
  response implies it should perform a physical action in-game.
  Returns a list of `{action, params}` tuples that can be executed
  by the Bot API.

  ## Examples

      iex> McFun.ActionParser.parse("Sure, I'll dig that block for you!", "Steve")
      [{:dig_looking_at, %{}}]

      iex> McFun.ActionParser.parse("On my way!", "Steve")
      [{:follow, %{target: "Steve"}}]

      iex> McFun.ActionParser.parse("Just chatting, nothing to do here.", "Steve")
      []
  """

  require Logger

  @type action :: {atom(), map()}

  @doc """
  Parse an LLM response string and return a list of actions to execute.

  The `player` argument is the username of the player who triggered
  the conversation — used as the default target for follow/goto actions.
  """
  @spec parse(String.t(), String.t()) :: [action()]
  def parse(response, player) do
    text = String.downcase(response)

    # Take only the first (highest-priority) match to avoid conflicting actions.
    # Pattern list is ordered by priority — dig before follow, follow before goto, etc.
    case Enum.find(patterns(), fn {_action, regex} -> Regex.match?(regex, text) end) do
      {action, _regex} -> [{action, params_for(action, text, player)}]
      nil -> []
    end
  end

  @doc """
  Execute a list of parsed actions against the Bot API.
  Returns a list of `{action, result}` tuples.
  """
  @spec execute([action()], String.t()) :: [{atom(), any()}]
  def execute(actions, bot_name) do
    Enum.map(actions, fn {action, params} ->
      result = execute_one(bot_name, action, params)
      Logger.info("ActionParser: #{bot_name} executed #{action} → #{inspect(result)}")
      {action, result}
    end)
  end

  # -- Pattern definitions --

  defp patterns do
    [
      {:dig_looking_at,
       ~r/i'll dig|let me dig|digging that|digging the|digging a|i'll mine|let me mine|mining that|mining the|mining a|i'll break|breaking that/},
      {:place,
       ~r/i'll place|placing a|placing the|let me place|i'll build|building a|building the|let me build/},
      {:jump, ~r/i'll jump|jumping|let me jump/},
      {:follow, ~r/following you|i'll follow|let me follow|right behind you/},
      {:goto,
       ~r/coming to you|on my way|i'll come|heading (to|your|over)|teleporting|going to you|let me come/},
      {:craft, ~r/i'll craft|crafting a|crafting an|crafting some|let me craft/},
      {:equip, ~r/i'll equip|equipping a|equipping the|equipping my|putting on|let me equip/},
      {:drop,
       ~r/i'll drop|dropping a|dropping an|dropping the|dropping my|here you go|take this/},
      {:attack, ~r/attacking|i'll attack|fighting|let me attack|i'll fight/},
      {:sneak, ~r/sneaking|crouching|i'll sneak|let me sneak/}
    ]
  end

  # -- Parameter extraction --

  defp params_for(:follow, _text, player), do: %{target: player}
  defp params_for(:goto, _text, player), do: %{target: player}
  defp params_for(:equip, text, _player), do: %{item: extract_item(text)}
  defp params_for(:craft, text, _player), do: %{item: extract_item(text)}
  defp params_for(_action, _text, _player), do: %{}

  # Try to extract an item name from phrases like "craft a wooden_pickaxe" or "equip diamond_sword"
  defp extract_item(text) do
    case Regex.run(~r/(?:craft|equip|make|putting on)\s+(?:a |an |the |some )?(\w+)/, text) do
      [_, item] -> item
      _ -> nil
    end
  end

  # -- Execution --

  defp execute_one(bot, :dig_looking_at, _params) do
    McFun.Bot.send_command(bot, %{action: "dig_looking_at"})
  end

  defp execute_one(bot, :jump, _params) do
    McFun.Bot.send_command(bot, %{action: "jump"})
  end

  defp execute_one(bot, :attack, _params) do
    McFun.Bot.send_command(bot, %{action: "attack"})
  end

  defp execute_one(bot, :sneak, _params) do
    McFun.Bot.send_command(bot, %{action: "sneak"})
  end

  defp execute_one(bot, :follow, %{target: target}) do
    McFun.Bot.send_command(bot, %{action: "follow", target: target})
  end

  defp execute_one(bot, :goto, %{target: target}) do
    McFun.Bot.send_command(bot, %{action: "goto", target: target})
  end

  defp execute_one(bot, :drop, _params) do
    McFun.Bot.drop(bot)
  end

  defp execute_one(bot, :equip, %{item: item}) when is_binary(item) do
    McFun.Bot.equip(bot, item)
  end

  defp execute_one(_bot, :equip, _params) do
    Logger.warning("ActionParser: equip action but couldn't extract item name")
    :skip
  end

  defp execute_one(bot, :craft, %{item: item}) when is_binary(item) do
    McFun.Bot.craft(bot, item)
  end

  defp execute_one(_bot, :craft, _params) do
    Logger.warning("ActionParser: craft action but couldn't extract item name")
    :skip
  end

  defp execute_one(bot, :place, _params) do
    # Place requires coordinates we don't have from text alone.
    # Log and skip for now — this will be extended later.
    Logger.info(
      "ActionParser: place action detected for #{bot} but no coordinates available — skipping"
    )

    :skip
  end

  defp execute_one(_bot, action, _params) do
    Logger.warning("ActionParser: unhandled action #{action}")
    :skip
  end
end
