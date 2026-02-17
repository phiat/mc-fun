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

  alias McFun.ChatBot.{Context, TextFilter, Tools}
  alias McFun.LLM.Groq
  alias McFun.LLM.ModelCache
  use GenServer, restart: :temporary
  require Logger

  @max_history 20
  @max_players 50
  @conversation_ttl_ms :timer.hours(1)
  @rate_limit_ms 2_000
  @fallback_model "openai/gpt-oss-20b"

  @heartbeat_initial_delay_ms 5_000

  @heartbeat_prompts [
    "What are you doing right now? Give a quick update.",
    "What's something interesting you notice around you?",
    "What's on your mind right now?",
    "Share a random fun fact related to what you see.",
    "Freestyle a quick 2-line rap about your situation.",
    "What would you suggest doing next around here?",
    "Rate your current mood on a scale and explain why.",
    "Describe your surroundings like a nature documentary narrator."
  ]

  defstruct [
    :bot_name,
    :personality,
    :model,
    conversations: %{},
    last_active: %{},
    last_response: nil,
    heartbeat_ref: nil,
    last_heartbeat: nil,
    heartbeat_enabled: true,
    last_message: nil,
    group_chat_enabled: true
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

  @doc "Wipe all memory: conversations, last message, last active timestamps."
  def wipe_memory(bot_name) do
    GenServer.call(via(bot_name), :wipe_memory)
  end

  @doc "Enable or disable heartbeat (ambient chat) for a bot."
  def toggle_heartbeat(bot_name, enabled?) do
    GenServer.call(via(bot_name), {:toggle_heartbeat, enabled?})
  end

  @doc "Enable or disable group chat (bot-to-bot) for a bot."
  def toggle_group_chat(bot_name, enabled?) do
    GenServer.call(via(bot_name), {:toggle_group_chat, enabled?})
  end

  @doc "Inject a message from another bot into this bot's conversation (used by FleetChat coordinator)."
  def inject_bot_message(bot_name, from_bot, message) do
    GenServer.cast(via(bot_name), {:inject_bot_message, from_bot, message})
  end

  @doc "Inject a topic for the bot to respond to naturally via LLM (used by FleetChat topic injection)."
  def inject_topic(bot_name, topic) do
    GenServer.cast(via(bot_name), {:inject_topic, topic})
  end

  @doc "Returns the list of heartbeat prompt strings (used by FleetChat to filter)."
  def heartbeat_prompts, do: @heartbeat_prompts

  defp via(bot_name), do: {:via, Registry, {McFun.BotRegistry, {:chat_bot, bot_name}}}

  # GenServer callbacks

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    personality = Keyword.get(opts, :personality, default_personality())
    model = Keyword.get(opts, :model, default_model())

    Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot_name}")

    Logger.info("ChatBot #{bot_name} started — model: #{model}")

    ref = Process.send_after(self(), :heartbeat, @heartbeat_initial_delay_ms)

    {:ok,
     %__MODULE__{
       bot_name: bot_name,
       personality: personality,
       model: model,
       heartbeat_ref: ref
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
  def handle_call(:wipe_memory, _from, state) do
    Logger.info("ChatBot #{state.bot_name} memory wiped")

    {:reply, :ok,
     %{state | conversations: %{}, last_active: %{}, last_response: nil, last_message: nil}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       bot_name: state.bot_name,
       model: state.model,
       personality: state.personality,
       conversations: state.conversations,
       conversation_players: Map.keys(state.conversations),
       heartbeat_enabled: state.heartbeat_enabled,
       group_chat_enabled: state.group_chat_enabled,
       last_message: state.last_message
     }, state}
  end

  @impl true
  def handle_call({:toggle_group_chat, enabled?}, _from, state) do
    Logger.info(
      "ChatBot #{state.bot_name} group chat #{if enabled?, do: "enabled", else: "disabled"}"
    )

    {:reply, :ok, %{state | group_chat_enabled: enabled?}}
  end

  @impl true
  def handle_call({:toggle_heartbeat, enabled?}, _from, state) do
    Logger.info(
      "ChatBot #{state.bot_name} heartbeat #{if enabled?, do: "enabled", else: "disabled"}"
    )

    state = %{state | heartbeat_enabled: enabled?}

    state =
      if enabled? do
        schedule_heartbeat(state)
      else
        if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
        %{state | heartbeat_ref: nil}
      end

    {:reply, :ok, state}
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

  # Whispers — only respond if this bot claims the whisper (prevents all bots responding)
  @impl true
  def handle_info(
        {:bot_event, _bot_name,
         %{"event" => "whisper", "username" => username, "message" => message}},
        state
      ) do
    if McFun.FleetChat.claim_whisper(state.bot_name, username, message) do
      Logger.info("ChatBot #{state.bot_name}: WHISPER from #{username}: #{inspect(message)}")
      state = handle_message(state, username, message, :whisper)
      {:noreply, state}
    else
      Logger.debug("ChatBot #{state.bot_name}: skipping whisper (claimed by another bot)")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:bot_event, _, _}, state), do: {:noreply, state}

  # LLM response with tool calls
  @impl true
  def handle_info({:llm_response, username, {:ok, response, tool_calls}, mode}, state) do
    reply = TextFilter.strip_thinking(response)

    # Broadcast stripped response to dashboard
    tools_str =
      Enum.map_join(tool_calls, ", ", fn %{name: n, args: a} -> "#{n}(#{inspect(a)})" end)

    broadcast_llm_event(state.bot_name, username, reply, tools_str)

    # Send chat and execute tools asynchronously to avoid blocking ChatBot
    bot_name = state.bot_name
    model = state.model
    personality = state.personality

    Task.start(fn ->
      # Always send a chat reply — if the LLM returned only tool calls with no text,
      # make a follow-up LLM call for a witty acknowledgement
      chat_reply =
        if reply != "" do
          reply
        else
          tool_names = Enum.map_join(tool_calls, ", ", & &1.name)

          Logger.info(
            "ChatBot #{bot_name}: empty text with tools [#{tool_names}], fetching follow-up chat"
          )

          fetch_followup_chat(bot_name, personality, model, tool_names, username)
        end

      broadcast_activity(bot_name, "chatting", username)
      TextFilter.send_paginated(bot_name, chat_reply, mode, username)

      for %{name: name, args: args} <- tool_calls do
        Logger.info("ChatBot #{bot_name}: tool call #{name}(#{inspect(args)})")

        try do
          Tools.execute(bot_name, name, args, username)
        catch
          kind, reason ->
            Logger.warning("ChatBot #{bot_name}: tool #{name} failed: #{kind} #{inspect(reason)}")
        end
      end

      # Clear activity after tools finish (unless a tool set its own action)
      broadcast_activity(bot_name, nil)
    end)

    state = state |> add_bot_response(username, response) |> track_last_message(response)
    {:noreply, state}
  end

  # LLM response text only (no tool calls) — fall back to regex parser
  @impl true
  def handle_info({:llm_response, username, {:ok, response}, mode}, state) do
    reply = TextFilter.strip_thinking(response)

    # Fallback: regex-based action parsing for models without tool support
    parsed_actions = McFun.ActionParser.parse(reply, username)

    actions_str =
      case parsed_actions do
        [] ->
          nil

        actions ->
          Logger.info("ChatBot #{state.bot_name}: regex fallback actions #{inspect(actions)}")
          Enum.map_join(actions, ", ", fn {action, _} -> to_string(action) end)
      end

    broadcast_llm_event(state.bot_name, username, reply, actions_str)

    # Send chat and execute actions asynchronously to avoid blocking ChatBot
    bot_name = state.bot_name

    Task.start(fn ->
      broadcast_activity(bot_name, "chatting", username)
      TextFilter.send_paginated(bot_name, reply, mode, username)

      if parsed_actions != [] do
        McFun.ActionParser.execute(parsed_actions, bot_name)
      else
        # No actions parsed — clear activity back to idle
        broadcast_activity(bot_name, nil)
      end
    end)

    state = state |> add_bot_response(username, response) |> track_last_message(response)
    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_response, _username, {:error, reason}, _mode}, state) do
    Logger.warning("ChatBot LLM error: #{inspect(reason)}")
    broadcast_activity(state.bot_name, nil)
    broadcast_llm_event(state.bot_name, nil, "LLM error: #{inspect(reason)}", nil)
    McFun.Bot.chat(state.bot_name, "Sorry, LLM error — try again!")
    {:noreply, state}
  end

  # Heartbeat — periodic ambient chat
  @impl true
  def handle_info(:heartbeat, %{heartbeat_enabled: false} = state) do
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    now = System.monotonic_time(:millisecond)

    # Skip if recent player conversation (within cooldown)
    if state.last_response && now - state.last_response < chat_bot_config(:heartbeat_cooldown_ms) do
      Logger.debug("ChatBot #{state.bot_name}: heartbeat skipped (recent conversation)")
      {:noreply, schedule_heartbeat(state)}
    else
      prompt = Enum.random(@heartbeat_prompts)
      bot_name = state.bot_name
      personality = state.personality
      model = state.model
      pid = self()

      broadcast_activity(bot_name, "thinking")

      Task.start(fn ->
        context = Context.build(bot_name)

        system_prompt =
          personality <>
            "\n\nYou are thinking out loud in Minecraft chat. " <>
            "Keep it to 1-2 sentences. No markdown. Be fun and in-character.\n" <>
            context <>
            "\n\nPrompt: #{prompt}"

        result =
          Groq.chat(system_prompt, [],
            max_tokens: chat_bot_config(:heartbeat_max_tokens),
            model: model,
            bot_name: bot_name
          )

        send(pid, {:heartbeat_response, result})
      end)

      {:noreply, state}
    end
  end

  # Heartbeat responses (ok with or without tool_calls)
  @impl true
  def handle_info({:heartbeat_response, {:ok, text}}, state) do
    {:noreply, handle_ambient_response(state, text, "heartbeat") |> schedule_heartbeat()}
  end

  @impl true
  def handle_info({:heartbeat_response, {:ok, text, _tool_calls}}, state) do
    {:noreply, handle_ambient_response(state, text, "heartbeat") |> schedule_heartbeat()}
  end

  @impl true
  def handle_info({:heartbeat_response, {:error, reason}}, state) do
    Logger.warning("ChatBot #{state.bot_name}: heartbeat LLM error: #{inspect(reason)}")
    broadcast_activity(state.bot_name, nil)
    {:noreply, schedule_heartbeat(state)}
  end

  # Topic injection responses (ok with or without tool_calls)
  @impl true
  def handle_info({:topic_response, {:ok, text}}, state) do
    {:noreply, handle_ambient_response(state, text, "topic")}
  end

  @impl true
  def handle_info({:topic_response, {:ok, text, _tool_calls}}, state) do
    {:noreply, handle_ambient_response(state, text, "topic")}
  end

  @impl true
  def handle_info({:topic_response, {:error, reason}}, state) do
    Logger.warning("ChatBot #{state.bot_name}: topic LLM error: #{inspect(reason)}")
    broadcast_activity(state.bot_name, nil)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Topic injection — bot generates a natural response to a topic via LLM
  @impl true
  def handle_cast({:inject_topic, topic}, state) do
    bot_name = state.bot_name
    personality = state.personality
    model = state.model
    pid = self()

    broadcast_activity(bot_name, "thinking")

    Task.start(fn ->
      context = Context.build(bot_name)

      system_prompt =
        personality <>
          "\n\nSomeone nearby brought up a topic in Minecraft chat. " <>
          "Respond naturally and in-character. Share your thoughts, ask a follow-up question, " <>
          "or riff on the idea. Do NOT repeat the topic back. " <>
          "Keep it to 1-2 sentences. No markdown. Be fun and in-character.\n" <>
          context <>
          "\n\nTopic: #{topic}"

      result =
        Groq.chat(system_prompt, [],
          max_tokens: chat_bot_config(:heartbeat_max_tokens),
          model: model,
          bot_name: bot_name
        )

      send(pid, {:topic_response, result})
    end)

    {:noreply, state}
  end

  # Bot-to-bot message injection from FleetChat coordinator
  @impl true
  def handle_cast({:inject_bot_message, from_bot, message}, state) do
    now = System.monotonic_time(:millisecond)

    Logger.info(
      "ChatBot #{state.bot_name}: injected bot message from #{from_bot}: #{inspect(message)}"
    )

    state = add_to_history(state, from_bot, message)
    spawn_response(state, from_bot)
    {:noreply, %{state | last_response: now}}
  end

  # Shared handler for heartbeat and topic ambient responses
  defp handle_ambient_response(state, text, tag) do
    reply = TextFilter.strip_thinking(text)

    if reply != "" do
      bot_name = state.bot_name
      broadcast_activity(bot_name, "chatting")

      Task.start(fn ->
        TextFilter.send_paginated(bot_name, reply)
        broadcast_activity(bot_name, nil)
      end)

      broadcast_llm_event(state.bot_name, nil, reply, tag)
    else
      broadcast_activity(state.bot_name, nil)
    end

    now = System.monotonic_time(:millisecond)
    %{track_last_message(state, text) | last_response: now}
  end

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

    available = ModelCache.model_ids()

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
    models = ModelCache.model_ids()

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

  # Whispers without prefix still get a response (whisper back, not public chat)
  defp handle_message(state, username, message, :whisper) do
    now = System.monotonic_time(:millisecond)

    if rate_limited?(state, now) do
      state
    else
      state = add_to_history(state, username, message)
      spawn_response(state, username, :whisper)
      %{state | last_response: now}
    end
  end

  # Regular chat — handled by FleetChat coordinator for bot-to-bot; ignored here
  defp handle_message(state, _username, _message, :chat), do: state

  # LLM interaction

  defp spawn_response(state, username, mode \\ :chat) do
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

    Logger.info(
      "ChatBot #{state.bot_name}: sending to Groq [#{model}] for #{username} (#{length(messages)} msgs)"
    )

    use_tools = Tools.supports_tools?(model)
    tools = if use_tools, do: Tools.definitions(), else: nil
    bot_name = state.bot_name

    broadcast_activity(bot_name, "thinking", username)

    Task.start_link(fn ->
      # Get environment context
      context = Context.build(bot_name, history: history)

      system_prompt =
        state.personality <>
          "\n\n" <>
          Tools.action_instructions(use_tools) <> context

      result =
        Groq.chat(system_prompt, messages,
          max_tokens: max_tokens_for(model),
          model: model,
          tools: tools,
          bot_name: bot_name
        )

      Logger.info("ChatBot Groq result: #{inspect(result, limit: 200)}")
      send(pid, {:llm_response, username, result, mode})
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

  defp track_last_message(state, text) do
    stripped = TextFilter.strip_thinking(text)
    if stripped != "", do: %{state | last_message: stripped}, else: state
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

  defp fetch_followup_chat(bot_name, personality, model, tool_names, username) do
    system_prompt =
      personality <>
        "\n\nYou just decided to use these actions: [#{tool_names}] in response to #{username}. " <>
        "Say something fun/witty to the player about what you're doing. " <>
        "1-2 sentences, no markdown."

    followup_tokens = chat_bot_config(:followup_max_tokens)

    case Groq.chat(system_prompt, [],
           max_tokens: followup_tokens,
           model: model,
           bot_name: bot_name
         ) do
      {:ok, text} ->
        reply = TextFilter.strip_thinking(text)
        if reply != "", do: reply, else: "On it!"

      {:ok, text, _tools} ->
        reply = TextFilter.strip_thinking(text)
        if reply != "", do: reply, else: "On it!"

      {:error, reason} ->
        Logger.warning("ChatBot #{bot_name}: follow-up chat failed: #{inspect(reason)}")
        "On it!"
    end
  end

  defp schedule_heartbeat(state) do
    # Cancel existing timer
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    interval =
      case McFun.BotBehaviors.info(state.bot_name) do
        %{behavior: _} -> chat_bot_config(:heartbeat_behavior_ms)
        _ -> chat_bot_config(:heartbeat_idle_ms)
      end

    ref = Process.send_after(self(), :heartbeat, interval)
    %{state | heartbeat_ref: ref}
  end

  defp default_model do
    Application.get_env(:mc_fun, :groq)[:model] || @fallback_model
  end

  defp chat_bot_config(key), do: Application.get_env(:mc_fun, :chat_bot)[key]

  defp broadcast_llm_event(bot_name, username, response, tools) do
    event = %{
      "event" => "llm_response",
      "username" => username,
      "response" => response,
      "tools" => tools
    }

    Phoenix.PubSub.broadcast(McFun.PubSub, "bot:#{bot_name}", {:bot_event, bot_name, event})
  end

  defp broadcast_activity(bot_name, activity, context \\ nil) do
    Phoenix.PubSub.broadcast(
      McFun.PubSub,
      "bot:#{bot_name}",
      {:bot_event, bot_name,
       %{"event" => "activity_change", "activity" => activity, "context" => context}}
    )
  end

  # Reasoning models need more tokens for chain-of-thought
  defp max_tokens_for(model_id) do
    cap = chat_bot_config(:max_response_tokens)

    case ModelCache.get_model(model_id) do
      {:ok, %{"max_completion_tokens" => max}} -> min(max, cap)
      _ -> div(cap, 2)
    end
  end

  defp default_personality do
    chat_bot_config(:default_personality)
  end
end
