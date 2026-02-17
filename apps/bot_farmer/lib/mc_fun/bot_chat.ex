defmodule McFun.BotChat do
  @moduledoc """
  Centralized bot-to-bot chat coordinator.

  Subscribes to all active bot PubSub topics and orchestrates conversations
  between nearby bots. Manages cooldowns, exchange limits, response chance,
  single-responder selection, and optional topic injection.
  """

  use GenServer
  require Logger

  @refresh_interval_ms 5_000

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

  @default_topics [
    "Hey, what do you think about this area?",
    "I wonder what's in that cave over there...",
    "Anyone want to go mining?",
    "What's the best thing you've found today?",
    "I think I heard something nearby...",
    "This is a nice spot, don't you think?",
    "Want to build something together?",
    "I bet I can find diamonds before you!",
    "Have you seen any cool structures around here?",
    "What should we do next?"
  ]

  @doc "Return the list of built-in default topics."
  def default_topics, do: @default_topics

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current BotChat coordinator status."
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{enabled: false, pairs: %{}, config: %{}}
  end

  def enable, do: GenServer.call(__MODULE__, :enable)
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Update a config key. Valid keys: :proximity, :max_exchanges, :cooldown_ms, :response_chance, :min_delay_ms, :max_delay_ms"
  def update_config(key, value) do
    GenServer.call(__MODULE__, {:update_config, key, value})
  end

  @doc "Inject a random topic as a bot chat message right now."
  def inject_topic do
    GenServer.cast(__MODULE__, :inject_topic_now)
  end

  @doc "Add a custom topic to the topic list."
  def add_topic(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:add_topic, topic})
  end

  @doc "Remove a custom topic from the topic list."
  def remove_topic(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:remove_topic, topic})
  end

  @doc "Enable or disable a specific topic."
  def toggle_topic(topic, enabled?) when is_binary(topic) do
    GenServer.call(__MODULE__, {:toggle_topic, topic, enabled?})
  end

  @doc "Enable or disable periodic topic injection."
  def toggle_topic_injection(enabled?) do
    GenServer.call(__MODULE__, {:toggle_topic_injection, enabled?})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    config = Application.get_env(:mc_fun, :bot_chat, [])

    state = %{
      enabled: Keyword.get(config, :enabled, true),
      config: %{
        proximity: Keyword.get(config, :proximity, 32),
        max_exchanges: Keyword.get(config, :max_exchanges, 3),
        cooldown_ms: Keyword.get(config, :cooldown_ms, 60_000),
        response_chance: Keyword.get(config, :response_chance, 0.7),
        min_delay_ms: Keyword.get(config, :min_delay_ms, 2_000),
        max_delay_ms: Keyword.get(config, :max_delay_ms, 5_000),
        topic_interval_ms: Keyword.get(config, :topic_interval_ms, 300_000)
      },
      pairs: %{},
      custom_topics: [],
      disabled_topics: MapSet.new(),
      topic_injection_enabled: Keyword.get(config, :topic_injection_enabled, false),
      topic_timer_ref: nil,
      subscribed_bots: MapSet.new(),
      pending_responses: MapSet.new()
    }

    Process.send_after(self(), :refresh_subscriptions, 1_000)

    state =
      if state.topic_injection_enabled do
        schedule_topic_injection(state)
      else
        state
      end

    Logger.info("BotChat coordinator started (enabled: #{state.enabled})")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       pairs: state.pairs,
       config: state.config,
       custom_topics: state.custom_topics,
       disabled_topics: MapSet.to_list(state.disabled_topics),
       topic_injection_enabled: state.topic_injection_enabled,
       subscribed_bots: MapSet.to_list(state.subscribed_bots)
     }, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    Logger.info("BotChat coordinator enabled")
    broadcast_update(%{state | enabled: true})
    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    Logger.info("BotChat coordinator disabled")
    broadcast_update(%{state | enabled: false})
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call({:update_config, key, value}, _from, state) when is_atom(key) do
    if Map.has_key?(state.config, key) do
      new_config = Map.put(state.config, key, value)
      new_state = %{state | config: new_config}
      broadcast_update(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :unknown_key}, state}
    end
  end

  @impl true
  def handle_call({:add_topic, topic}, _from, state) do
    topics = [topic | state.custom_topics] |> Enum.uniq()
    new_state = %{state | custom_topics: topics}
    broadcast_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_topic, topic}, _from, state) do
    topics = List.delete(state.custom_topics, topic)
    disabled = MapSet.delete(state.disabled_topics, topic)
    new_state = %{state | custom_topics: topics, disabled_topics: disabled}
    broadcast_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:toggle_topic, topic, true}, _from, state) do
    new_state = %{state | disabled_topics: MapSet.delete(state.disabled_topics, topic)}
    broadcast_update(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:toggle_topic, topic, false}, _from, state) do
    new_state = %{state | disabled_topics: MapSet.put(state.disabled_topics, topic)}
    broadcast_update(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:toggle_topic_injection, enabled?}, _from, state) do
    state =
      if enabled? do
        Logger.info("BotChat topic injection enabled")
        schedule_topic_injection(state)
      else
        Logger.info("BotChat topic injection disabled")

        if state.topic_timer_ref do
          Process.cancel_timer(state.topic_timer_ref)
        end

        %{state | topic_injection_enabled: false, topic_timer_ref: nil}
      end

    state = %{state | topic_injection_enabled: enabled?}
    broadcast_update(state)
    {:reply, :ok, state}
  end

  # Chat event from a bot
  @impl true
  def handle_info(
        {:bot_event, sender, %{"event" => "chat", "message" => message}},
        %{enabled: true} = state
      ) do
    known_bots = MapSet.to_list(state.subscribed_bots)

    if sender in known_bots and not heartbeat_message?(message) do
      {:noreply, maybe_trigger_response(state, sender, message, known_bots)}
    else
      {:noreply, state}
    end
  end

  # Delayed response trigger
  @impl true
  def handle_info({:trigger_response, responder, sender, message}, state) do
    new_pending = MapSet.delete(state.pending_responses, responder)
    state = %{state | pending_responses: new_pending}

    # Verify responder still exists and has group chat enabled
    if bot_alive?(responder) and group_chat_enabled?(responder) do
      Logger.info("BotChat: triggering #{responder} to respond to #{sender}")
      McFun.ChatBot.inject_bot_message(responder, sender, message)

      # Update pair state
      pair_key = pair_key(sender, responder)
      pair = Map.get(state.pairs, pair_key, %{count: 0, cooldown_until: nil, last_at: nil})
      now = System.monotonic_time(:millisecond)
      new_count = pair.count + 1

      pair =
        if new_count >= state.config.max_exchanges do
          %{pair | count: 0, cooldown_until: now + state.config.cooldown_ms, last_at: now}
        else
          %{pair | count: new_count, last_at: now}
        end

      new_state = %{state | pairs: Map.put(state.pairs, pair_key, pair)}
      broadcast_update(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Topic injection timer
  @impl true
  def handle_info(:inject_topic, state) do
    state = do_inject_topic(state)
    state = schedule_topic_injection(state)
    {:noreply, state}
  end

  # Refresh bot subscriptions
  @impl true
  def handle_info(:refresh_subscriptions, state) do
    current_bots = MapSet.new(safe_list_bots())

    # Subscribe to new bots
    for bot <- MapSet.difference(current_bots, state.subscribed_bots) do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    # Unsubscribe from dead bots
    for bot <- MapSet.difference(state.subscribed_bots, current_bots) do
      Phoenix.PubSub.unsubscribe(McFun.PubSub, "bot:#{bot}")
    end

    Process.send_after(self(), :refresh_subscriptions, @refresh_interval_ms)
    {:noreply, %{state | subscribed_bots: current_bots}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:inject_topic_now, state) do
    {:noreply, do_inject_topic(state)}
  end

  # Internal helpers

  defp maybe_trigger_response(state, sender, message, known_bots) do
    # Find nearby bots (excluding sender) with group chat enabled
    candidates =
      known_bots
      |> Enum.reject(&(&1 == sender))
      |> Enum.filter(fn bot ->
        bot_alive?(bot) and
          group_chat_enabled?(bot) and
          bot_nearby?(sender, bot, state.config.proximity) and
          not MapSet.member?(state.pending_responses, bot) and
          pair_available?(state, sender, bot)
      end)

    if candidates == [] do
      state
    else
      # Roll response chance (boost if bot name mentioned)
      chance =
        if Enum.any?(candidates, &String.contains?(message, &1)) do
          min(1.0, state.config.response_chance + 0.2)
        else
          state.config.response_chance
        end

      if :rand.uniform() <= chance do
        # Pick one responder
        responder = Enum.random(candidates)
        delay = Enum.random(state.config.min_delay_ms..state.config.max_delay_ms)

        Logger.info("BotChat: scheduling #{responder} to respond to #{sender} in #{delay}ms")

        Process.send_after(self(), {:trigger_response, responder, sender, message}, delay)
        %{state | pending_responses: MapSet.put(state.pending_responses, responder)}
      else
        state
      end
    end
  end

  defp pair_available?(state, bot_a, bot_b) do
    key = pair_key(bot_a, bot_b)
    pair = Map.get(state.pairs, key, %{count: 0, cooldown_until: nil})
    now = System.monotonic_time(:millisecond)

    cond do
      pair.cooldown_until && now < pair.cooldown_until -> false
      pair.count >= state.config.max_exchanges -> false
      true -> true
    end
  end

  defp pair_key(a, b), do: if(a < b, do: {a, b}, else: {b, a})

  defp bot_nearby?(bot_a, bot_b, proximity) do
    case {safe_bot_status(bot_a), safe_bot_status(bot_b)} do
      {%{position: {x1, y1, z1}}, %{position: {x2, y2, z2}}}
      when is_number(x1) and is_number(x2) ->
        distance = :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2 + (z2 - z1) ** 2)
        distance <= proximity

      _ ->
        false
    end
  end

  defp group_chat_enabled?(bot_name) do
    case safe_chatbot_info(bot_name) do
      %{group_chat_enabled: enabled} -> enabled
      _ -> false
    end
  end

  defp bot_alive?(bot_name) do
    Registry.lookup(McFun.BotRegistry, {:chat_bot, bot_name}) != []
  end

  defp heartbeat_message?(message) do
    Enum.any?(@heartbeat_prompts, &String.contains?(message, &1))
  end

  defp do_inject_topic(state) do
    bots = MapSet.to_list(state.subscribed_bots)

    enabled_topics =
      (@default_topics ++ state.custom_topics)
      |> Enum.reject(&MapSet.member?(state.disabled_topics, &1))

    if bots != [] and enabled_topics != [] do
      topic = Enum.random(enabled_topics)
      bot = Enum.random(bots)

      Logger.info("BotChat: injecting topic via #{bot}: #{topic}")

      try do
        McFun.ChatBot.inject_topic(bot, topic)
      catch
        _, _ -> :ok
      end
    end

    state
  end

  defp schedule_topic_injection(state) do
    if state.topic_timer_ref do
      Process.cancel_timer(state.topic_timer_ref)
    end

    ref = Process.send_after(self(), :inject_topic, state.config.topic_interval_ms)
    %{state | topic_timer_ref: ref, topic_injection_enabled: true}
  end

  defp broadcast_update(state) do
    Phoenix.PubSub.broadcast(
      McFun.PubSub,
      "bot_chat",
      {:bot_chat_updated,
       %{
         enabled: state.enabled,
         pairs: state.pairs,
         config: state.config,
         custom_topics: state.custom_topics,
         disabled_topics: MapSet.to_list(state.disabled_topics),
         topic_injection_enabled: state.topic_injection_enabled
       }}
    )
  end

  defp safe_list_bots do
    McFun.BotSupervisor.list_bots()
  rescue
    _ -> []
  end

  defp safe_bot_status(bot_name) do
    case McFun.Bot.status(bot_name) do
      {:error, _} -> %{}
      status -> status
    end
  catch
    _, _ -> %{}
  end

  defp safe_chatbot_info(bot_name) do
    McFun.ChatBot.info(bot_name)
  catch
    _, _ -> nil
  end
end
