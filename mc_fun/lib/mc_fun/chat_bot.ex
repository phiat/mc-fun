defmodule McFun.ChatBot do
  @moduledoc """
  LLM-powered chat bot that listens to mineflayer events and responds via Groq.
  Maintains conversation history per player with configurable personality.

  ## Commands (in-game)

  - `!ask <question>` — ask the LLM a question
  - `!model <id>` — switch to a different Groq model
  - `!models` — list available models
  - `!personality <text>` — change the bot's personality
  - `!reset` — clear conversation history

  Whispers always trigger a response (no prefix needed).
  """
  use GenServer
  require Logger

  @max_history 20
  @max_players 50
  @conversation_ttl_ms :timer.hours(1)
  @rate_limit_ms 2_000
  @max_response_length 200
  @default_model "openai/gpt-oss-20b"

  defstruct [
    :bot_name,
    :personality,
    :model,
    conversations: %{},
    last_active: %{},
    last_response: nil
  ]

  # Client API

  def start_link(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    GenServer.start_link(__MODULE__, opts, name: via(bot_name))
  end

  @doc "Change the active model for a running ChatBot."
  def set_model(bot_name, model_id) do
    GenServer.call(via(bot_name), {:set_model, model_id})
  end

  @doc "Change the personality for a running ChatBot."
  def set_personality(bot_name, personality) do
    GenServer.call(via(bot_name), {:set_personality, personality})
  end

  @doc "Get current state info."
  def info(bot_name) do
    GenServer.call(via(bot_name), :info)
  end

  defp via(bot_name), do: {:via, Registry, {McFun.BotRegistry, {:chat_bot, bot_name}}}

  # GenServer callbacks

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    personality = Keyword.get(opts, :personality, default_personality())
    model = Keyword.get(opts, :model, @default_model)

    Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot_name}")

    Logger.info("ChatBot #{bot_name} started — model: #{model}")

    {:ok,
     %__MODULE__{
       bot_name: bot_name,
       personality: personality,
       model: model
     }}
  end

  @impl true
  def handle_call({:set_model, model_id}, _from, state) do
    Logger.info("ChatBot #{state.bot_name} model changed to #{model_id}")
    McFun.Bot.chat(state.bot_name, "Model switched to #{model_id}")
    {:reply, :ok, %{state | model: model_id}}
  end

  @impl true
  def handle_call({:set_personality, personality}, _from, state) do
    McFun.Bot.chat(state.bot_name, "Personality updated!")
    {:reply, :ok, %{state | personality: personality}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       bot_name: state.bot_name,
       model: state.model,
       personality: state.personality,
       conversations: state.conversations,
       conversation_players: Map.keys(state.conversations)
     }, state}
  end

  # Chat events — only respond to !commands
  @impl true
  def handle_info(
        {:bot_event, _bot_name,
         %{"event" => "chat", "username" => username, "message" => message}},
        state
      ) do
    Logger.info("ChatBot #{state.bot_name}: CHAT from #{username}: #{inspect(message)}")
    state = handle_message(state, username, message, :chat)
    {:noreply, state}
  end

  # Whispers always get a response
  @impl true
  def handle_info(
        {:bot_event, _bot_name,
         %{"event" => "whisper", "username" => username, "message" => message}},
        state
      ) do
    Logger.info("ChatBot #{state.bot_name}: WHISPER from #{username}: #{inspect(message)}")
    state = handle_message(state, username, message, :whisper)
    {:noreply, state}
  end

  @impl true
  def handle_info({:bot_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:llm_response, username, {:ok, response}}, state) do
    response = truncate(response, @max_response_length)

    # Send text response to chat
    McFun.Bot.chat(state.bot_name, response)

    # Parse and execute any actions implied by the response
    case McFun.ActionParser.parse(response, username) do
      [] ->
        :ok

      actions ->
        Logger.info("ChatBot #{state.bot_name}: detected actions #{inspect(actions)} from response")
        McFun.ActionParser.execute(actions, state.bot_name)
    end

    state = add_bot_response(state, username, response)
    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response, _username, {:error, reason}}, state) do
    Logger.warning("ChatBot LLM error: #{inspect(reason)}")
    McFun.Bot.chat(state.bot_name, "Sorry, LLM error — try again!")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Rate limiting

  defp rate_limited?(%{last_response: nil}, _now), do: false
  defp rate_limited?(state, now), do: now - state.last_response < @rate_limit_ms

  # Message handling

  defp handle_message(state, username, "!ask " <> question, _mode) do
    now = System.monotonic_time(:millisecond)

    if rate_limited?(state, now) do
      Logger.info("ChatBot: rate limited, ignoring !ask from #{username}")
      state
    else
      Logger.info("ChatBot: !ask from #{username}: #{inspect(question)}")
      state = add_to_history(state, username, question)
      spawn_response(state, username)
      %{state | last_response: now}
    end
  end

  defp handle_message(state, _username, "!model " <> model_id, _mode) do
    model_id = String.trim(model_id)

    available = McFun.LLM.ModelCache.model_ids()

    if available == [] or model_id in available do
      McFun.Bot.chat(state.bot_name, "Switched to #{model_id}")
      %{state | model: model_id}
    else
      # Try fuzzy match
      match = Enum.find(available, &String.contains?(&1, model_id))

      if match do
        McFun.Bot.chat(state.bot_name, "Switched to #{match}")
        %{state | model: match}
      else
        McFun.Bot.chat(state.bot_name, "Unknown model. Try !models to see available ones.")
        state
      end
    end
  end

  defp handle_message(state, _username, "!models", _mode) do
    models = McFun.LLM.ModelCache.model_ids()

    if models == [] do
      McFun.Bot.chat(state.bot_name, "No models cached yet. Set GROQ_API_KEY to fetch.")
    else
      # Send in chunks to avoid chat length limits
      McFun.Bot.chat(state.bot_name, "Available models (#{length(models)}):")

      models
      |> Enum.chunk_every(5)
      |> Enum.each(fn chunk ->
        Process.sleep(300)
        McFun.Bot.chat(state.bot_name, Enum.join(chunk, ", "))
      end)
    end

    state
  end

  defp handle_message(state, _username, "!personality " <> personality, _mode) do
    McFun.Bot.chat(state.bot_name, "Personality updated!")
    %{state | personality: personality}
  end

  defp handle_message(state, username, "!reset", _mode) do
    McFun.Bot.chat(state.bot_name, "Chat history cleared for #{username}!")
    %{state | conversations: Map.delete(state.conversations, username)}
  end

  defp handle_message(state, username, "!tp", _mode) do
    McFun.Bot.teleport_to(state.bot_name, username)
    McFun.Bot.chat(state.bot_name, "Teleporting to #{username}!")
    state
  end

  defp handle_message(state, _username, "!tp " <> target, _mode) do
    McFun.Bot.teleport_to(state.bot_name, String.trim(target))
    McFun.Bot.chat(state.bot_name, "Teleporting to #{String.trim(target)}!")
    state
  end

  # Whispers without prefix still get a response
  defp handle_message(state, username, message, :whisper) do
    now = System.monotonic_time(:millisecond)

    if rate_limited?(state, now) do
      state
    else
      state = add_to_history(state, username, message)
      spawn_response(state, username)
      %{state | last_response: now}
    end
  end

  # Regular chat without prefix — ignore
  defp handle_message(state, _username, _message, :chat), do: state

  # LLM interaction

  defp spawn_response(state, username) do
    pid = self()
    history = Map.get(state.conversations, username, [])
    model = state.model

    messages =
      history
      |> Enum.reverse()
      |> Enum.map(fn
        {:player, msg} -> {:user, "#{username}: #{msg}"}
        {:bot, msg} -> {:assistant, msg}
      end)

    Logger.info("ChatBot #{state.bot_name}: sending to Groq [#{model}] for #{username} (#{length(messages)} msgs)")

    Task.start_link(fn ->
      result =
        McFun.LLM.Groq.chat(state.personality, messages,
          max_tokens: 150,
          model: model
        )

      Logger.info("ChatBot Groq result: #{inspect(result, limit: 200)}")
      send(pid, {:llm_response, username, result})
    end)
  end

  defp add_to_history(state, username, message) do
    history = Map.get(state.conversations, username, [])
    history = [{:player, message} | history] |> Enum.take(@max_history)
    state = %{state | conversations: Map.put(state.conversations, username, history)}
    touch_and_evict(state, username)
  end

  defp add_bot_response(state, username, response) do
    history = Map.get(state.conversations, username, [])
    history = [{:bot, response} | history] |> Enum.take(@max_history)
    %{state | conversations: Map.put(state.conversations, username, history)}
  end

  # Track last activity and evict stale/excess conversations
  defp touch_and_evict(state, username) do
    now = System.monotonic_time(:millisecond)
    last_active = Map.put(state.last_active, username, now)

    # Evict conversations inactive for > TTL
    expired =
      last_active
      |> Enum.filter(fn {_player, ts} -> now - ts > @conversation_ttl_ms end)
      |> Enum.map(fn {player, _} -> player end)

    conversations = Map.drop(state.conversations, expired)
    last_active = Map.drop(last_active, expired)

    # If still over cap, evict oldest
    {conversations, last_active} =
      if map_size(conversations) > @max_players do
        oldest =
          last_active
          |> Enum.sort_by(fn {_, ts} -> ts end)
          |> Enum.take(map_size(conversations) - @max_players)
          |> Enum.map(fn {player, _} -> player end)

        {Map.drop(conversations, oldest), Map.drop(last_active, oldest)}
      else
        {conversations, last_active}
      end

    %{state | conversations: conversations, last_active: last_active}
  end

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  defp default_personality do
    """
    You are a friendly Minecraft bot. You chat with players in-game.
    Keep responses SHORT (1-2 sentences max). Be fun, helpful, and in-character.
    You live in the Minecraft world. You can see, mine, build, and fight.
    Don't use markdown formatting. Just plain text suitable for Minecraft chat.

    IMPORTANT: You can actually perform actions! When a player asks you to do something,
    respond with action words to trigger them:
    - Say "I'll dig" or "mining" to dig the block you're looking at
    - Say "I'll jump" or "jumping" to jump
    - Say "following you" or "I'll follow" to follow the player
    - Say "on my way" or "coming to you" to go to the player
    - Say "I'll attack" or "attacking" to attack the nearest entity
    - Say "I'll drop" or "dropping" to drop your held item
    - Say "sneaking" or "crouching" to sneak
    - Say "I'll craft" to craft something
    - Say "I'll equip" to equip something
    Always use these action phrases when agreeing to do something physical.
    """
  end
end
