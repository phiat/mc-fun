defmodule BotFarmer do
  @moduledoc """
  Public API for the bot fleet manager.

  Thin facade delegating to McFun.Bot, McFun.ChatBot, McFun.BotBehaviors,
  McFun.BotChat, McFun.BotSupervisor, and McFun.Presets. Dashboard code
  should call BotFarmer.* instead of reaching into internals directly.
  """

  require Logger

  # ── Fleet lifecycle ──────────────────────────────────────────────────

  @doc "Spawn a bot, optionally attach chatbot and start a behavior."
  def spawn_bot(name, opts \\ []) do
    model = Keyword.get(opts, :model)
    personality = Keyword.get(opts, :personality)
    behavior = Keyword.get(opts, :behavior)

    case McFun.BotSupervisor.spawn_bot(name) do
      {:ok, pid} ->
        BotFarmer.BotStore.save(name, opts)
        {:ok, pid, %{model: model, personality: personality, behavior: behavior}}

      error ->
        error
    end
  end

  @doc "Stop a bot and its chatbot/behavior."
  def stop_bot(name) do
    detach_chatbot(name)
    stop_behavior(name)
    result = McFun.BotSupervisor.stop_bot(name)
    BotFarmer.BotStore.remove(name)
    result
  end

  @doc "Stop all running bots."
  def stop_all do
    for bot <- list_bots() do
      stop_bot(bot)
    end

    :ok
  end

  @doc "List all running bot names."
  def list_bots do
    McFun.BotSupervisor.list_bots()
  rescue
    _ -> []
  end

  @doc "Get aggregated status for a bot."
  def bot_status(name) do
    bot_status = try_bot_status(name)
    chatbot_info = try_chatbot_info(name)
    behavior_info = try_behavior_info(name)

    %{
      position: bot_status[:position],
      health: bot_status[:health],
      food: bot_status[:food],
      dimension: bot_status[:dimension],
      inventory: bot_status[:inventory] || [],
      chatbot: chatbot_info != nil,
      model: chatbot_info && chatbot_info[:model],
      personality: chatbot_info && chatbot_info[:personality],
      conversations: chatbot_info && chatbot_info[:conversations],
      conversation_players: chatbot_info && chatbot_info[:conversation_players],
      heartbeat_enabled: chatbot_info && chatbot_info[:heartbeat_enabled],
      group_chat_enabled: chatbot_info && chatbot_info[:group_chat_enabled],
      last_message: chatbot_info && chatbot_info[:last_message],
      behavior: behavior_info,
      cost: McFun.CostTracker.get_bot_cost(name)
    }
  end

  # ── ChatBot controls ─────────────────────────────────────────────────

  def set_model(name, model) do
    result = McFun.ChatBot.set_model(name, model)
    BotFarmer.BotStore.update(name, model: model)
    result
  end

  def set_personality(name, personality) do
    result = McFun.ChatBot.set_personality(name, personality)
    BotFarmer.BotStore.update(name, personality: personality)
    result
  end

  def toggle_heartbeat(name, enabled?) do
    result = McFun.ChatBot.toggle_heartbeat(name, enabled?)
    BotFarmer.BotStore.update(name, heartbeat_enabled: enabled?)
    result
  end

  def toggle_group_chat(name, enabled?) do
    result = McFun.ChatBot.toggle_group_chat(name, enabled?)
    BotFarmer.BotStore.update(name, group_chat_enabled: enabled?)
    result
  end

  def wipe_memory(name), do: McFun.ChatBot.wipe_memory(name)

  def chatbot_info(name) do
    McFun.ChatBot.info(name)
  catch
    _, _ -> nil
  end

  @doc "Attach a chatbot to a running bot."
  def attach_chatbot(name, opts \\ []) do
    spec = {McFun.ChatBot, Keyword.put(opts, :bot_name, name)}

    case DynamicSupervisor.start_child(McFun.BotSupervisor, spec) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        model = Keyword.get(opts, :model)
        personality = Keyword.get(opts, :personality)

        try do
          if model, do: McFun.ChatBot.set_model(name, model)
          if personality, do: McFun.ChatBot.set_personality(name, personality)
        catch
          _, _ -> :ok
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Detach (stop) the chatbot for a bot."
  def detach_chatbot(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end

  # ── Bot actions ──────────────────────────────────────────────────────

  def chat(name, msg), do: McFun.Bot.chat(name, msg)
  def send_command(name, cmd), do: McFun.Bot.send_command(name, cmd)
  def teleport_to(name, target), do: McFun.Bot.teleport_to(name, target)
  def drop_item(name, item, count \\ nil), do: McFun.Bot.drop_item(name, item, count)
  def drop_all(name), do: McFun.Bot.drop_all(name)

  # ── Behaviors ────────────────────────────────────────────────────────

  def start_patrol(name, waypoints) do
    result = McFun.BotBehaviors.start_patrol(name, waypoints)
    BotFarmer.BotStore.update(name, behavior: %{type: :patrol, params: %{waypoints: waypoints}})
    result
  end

  def start_follow(name, target) do
    result = McFun.BotBehaviors.start_follow(name, target)
    BotFarmer.BotStore.update(name, behavior: %{type: :follow, params: %{target: target}})
    result
  end

  def start_guard(name, pos, opts \\ []) do
    result = McFun.BotBehaviors.start_guard(name, pos, opts)

    BotFarmer.BotStore.update(name,
      behavior: %{
        type: :guard,
        params: %{position: pos, radius: Keyword.get(opts, :radius, 8)}
      }
    )

    result
  end

  def start_mine(name, block_type, opts \\ []) do
    result = McFun.BotBehaviors.start_mine(name, block_type, opts)

    BotFarmer.BotStore.update(name,
      behavior: %{
        type: :mine,
        params: %{
          block_type: block_type,
          max_distance: Keyword.get(opts, :max_distance, 32),
          max_count: Keyword.get(opts, :max_count, :infinity)
        }
      }
    )

    result
  end

  def stop_behavior(name) do
    result = McFun.BotBehaviors.stop(name)
    BotFarmer.BotStore.update(name, behavior: nil)
    result
  end

  def behavior_info(name) do
    McFun.BotBehaviors.info(name)
  end

  # ── BotChat coordinator ──────────────────────────────────────────────

  def bot_chat_status, do: McFun.BotChat.status()
  def bot_chat_enable, do: McFun.BotChat.enable()
  def bot_chat_disable, do: McFun.BotChat.disable()
  def bot_chat_config(key, value), do: McFun.BotChat.update_config(key, value)
  def inject_topic, do: McFun.BotChat.inject_topic()
  def add_topic(t), do: McFun.BotChat.add_topic(t)
  def remove_topic(t), do: McFun.BotChat.remove_topic(t)
  def toggle_topic(t, on?), do: McFun.BotChat.toggle_topic(t, on?)
  def toggle_topic_injection(on?), do: McFun.BotChat.toggle_topic_injection(on?)
  def default_topics, do: McFun.BotChat.default_topics()

  # ── Presets ──────────────────────────────────────────────────────────

  def presets_by_category, do: McFun.Presets.by_category()
  def get_preset(id), do: McFun.Presets.get(id)

  # ── Internal helpers ─────────────────────────────────────────────────

  defp try_bot_status(name) do
    case McFun.Bot.status(name) do
      {:error, _} -> %{}
      status when is_map(status) -> status
    end
  catch
    _, _ -> %{}
  end

  defp try_chatbot_info(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{_, _}] -> McFun.ChatBot.info(name)
      [] -> nil
    end
  catch
    _, _ -> nil
  end

  defp try_behavior_info(name) do
    case McFun.BotBehaviors.info(name) do
      {:error, :no_behavior} -> nil
      info when is_map(info) -> info
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
