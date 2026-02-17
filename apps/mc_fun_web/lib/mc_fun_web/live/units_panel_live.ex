defmodule McFunWeb.UnitsPanelLive do
  @moduledoc "Units/Deploy panel LiveComponent — bot deployment, management, and status cards."
  use McFunWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:bot_spawn_name, fn -> "McFunBot" end)
     |> assign_new(:selected_model, fn ->
       Application.get_env(:mc_fun, :groq)[:model] || "openai/gpt-oss-20b"
     end)
     |> assign_new(:selected_preset, fn -> nil end)
     |> assign_new(:deploy_personality, fn -> default_personality() end)
     |> assign_new(:pending_card_models, fn -> %{} end)
     |> assign_new(:failed_bots, fn -> %{} end)
     |> assign_new(:bot_chat_status, fn -> %{enabled: false, pairs: %{}, config: %{}} end)
     |> assign_new(:new_topic, fn -> "" end)
     |> assign_new(:interaction_open, fn -> false end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="panel-bots" role="tabpanel" class="space-y-4">
      <%!-- Deploy Panel --%>
      <McFunWeb.DashboardComponents.deploy_panel
        selected_model={@selected_model}
        selected_preset={@selected_preset}
        deploy_personality={@deploy_personality}
        available_models={@available_models}
        bot_spawn_name={@bot_spawn_name}
        target={@myself}
      />

      <%!-- Failed Bots --%>
      <div
        :for={{bot_name, reason} <- @failed_bots}
        class="border-2 border-[#ff4444]/40 bg-[#1a0a0a] p-4 flex items-center justify-between"
      >
        <div>
          <span class="text-sm font-bold text-[#ff4444]">{bot_name}</span>
          <span class="text-[10px] text-[#888] ml-2 tracking-wider">KICKED: {reason}</span>
        </div>
        <div class="flex gap-2">
          <%= if String.contains?(String.downcase(reason), "not whitelisted") do %>
            <button
              phx-click="whitelist_and_deploy"
              phx-target={@myself}
              phx-value-name={bot_name}
              class="px-4 py-1.5 border-2 border-[#00ff88] text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10 transition-all"
            >
              WHITELIST &amp; DEPLOY
            </button>
          <% end %>
          <button
            phx-click="dismiss_failed"
            phx-target={@myself}
            phx-value-name={bot_name}
            class="px-3 py-1.5 border border-[#444] text-[#666] text-[10px] tracking-widest hover:text-[#aaa] transition-all"
          >
            DISMISS
          </button>
        </div>
      </div>

      <%!-- Active Units --%>
      <div class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
        <div class="flex items-center justify-between mb-3">
          <div class="text-[10px] tracking-widest text-[#888]">
            ACTIVE UNITS <span class="text-[#00ffff]">[{length(@bots)}]</span>
          </div>
        </div>

        <div :if={@bots == []} class="text-center py-8 text-[#333] text-xs">
          NO UNITS DEPLOYED
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          <McFunWeb.DashboardComponents.bot_card
            :for={bot <- @bots}
            bot={bot}
            status={@bot_statuses[bot]}
            online_players={@online_players}
            available_models={@available_models}
            pending_model={@pending_card_models[bot]}
            target={@myself}
          />
        </div>
      </div>

      <%!-- Bot Interaction Config (collapsible) --%>
      <div class="border-2 border-[#aa66ff]/20 bg-[#0d0d14]">
        <button
          phx-click="toggle_interaction_panel"
          phx-target={@myself}
          class="w-full flex items-center justify-between px-4 py-3 hover:bg-[#aa66ff]/5 transition-all"
        >
          <div class="flex items-center gap-3">
            <span class={"text-[10px] tracking-widest transition-transform " <>
              if(@interaction_open, do: "rotate-90", else: "")}>
              ▶
            </span>
            <span class="text-[10px] tracking-widest text-[#aa66ff]/60">BOT INTERACTION</span>
            <span class={"w-1.5 h-1.5 " <>
              if(@bot_chat_status[:enabled],
                do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]",
                else: "bg-[#ff4444] shadow-[0_0_4px_#ff4444]")} />
          </div>
          <span class={"px-3 py-0.5 border text-[9px] tracking-widest " <>
            if(@bot_chat_status[:enabled],
              do: "border-[#00ff88]/40 text-[#00ff88]",
              else: "border-[#ff4444]/40 text-[#ff4444]")}>
            {if @bot_chat_status[:enabled], do: "ON", else: "OFF"}
          </span>
        </button>

        <div :if={@interaction_open} class="px-4 pb-4 space-y-3">
          <div class="flex justify-end">
            <button
              phx-click="toggle_bot_chat"
              phx-target={@myself}
              class={"px-4 py-1 border text-[10px] tracking-widest transition-all " <>
                if(@bot_chat_status[:enabled],
                  do: "border-[#00ff88] text-[#00ff88] hover:bg-[#00ff88]/10",
                  else: "border-[#ff4444] text-[#ff4444] hover:bg-[#ff4444]/10")}
            >
              {if @bot_chat_status[:enabled], do: "DISABLE", else: "ENABLE"}
            </button>
          </div>

          <div :if={@bot_chat_status[:enabled]} class="space-y-3">
            <%!-- Config row --%>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div>
                <label class="text-[9px] tracking-wider text-[#666] block mb-0.5">PROXIMITY</label>
                <input
                  type="number"
                  value={get_in(@bot_chat_status, [:config, :proximity]) || 32}
                  phx-change="update_bot_chat_config"
                  phx-target={@myself}
                  phx-debounce="500"
                  name="proximity"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#aa66ff] focus:outline-none"
                />
              </div>
              <div>
                <label class="text-[9px] tracking-wider text-[#666] block mb-0.5">
                  MAX EXCHANGES
                </label>
                <input
                  type="number"
                  value={get_in(@bot_chat_status, [:config, :max_exchanges]) || 3}
                  phx-change="update_bot_chat_config"
                  phx-target={@myself}
                  phx-debounce="500"
                  name="max_exchanges"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#aa66ff] focus:outline-none"
                />
              </div>
              <div>
                <label class="text-[9px] tracking-wider text-[#666] block mb-0.5">COOLDOWN (s)</label>
                <input
                  type="number"
                  value={div(get_in(@bot_chat_status, [:config, :cooldown_ms]) || 60_000, 1000)}
                  phx-change="update_bot_chat_config"
                  phx-target={@myself}
                  phx-debounce="500"
                  name="cooldown_s"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#aa66ff] focus:outline-none"
                />
              </div>
              <div>
                <label class="text-[9px] tracking-wider text-[#666] block mb-0.5">CHANCE %</label>
                <input
                  type="number"
                  value={trunc((get_in(@bot_chat_status, [:config, :response_chance]) || 0.7) * 100)}
                  phx-change="update_bot_chat_config"
                  phx-target={@myself}
                  phx-debounce="500"
                  name="chance_pct"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#aa66ff] focus:outline-none"
                />
              </div>
            </div>

            <%!-- Topic injection --%>
            <div class="border border-[#222] p-3">
              <div class="flex items-center justify-between mb-2">
                <div class="text-[9px] tracking-widest text-[#aa66ff]/80">TOPIC INJECTION</div>
                <div class="flex gap-2">
                  <button
                    phx-click="toggle_topic_injection"
                    phx-target={@myself}
                    class={"px-3 py-0.5 border text-[9px] tracking-widest transition-all " <>
                      if(@bot_chat_status[:topic_injection_enabled],
                        do: "border-[#00ff88] text-[#00ff88] hover:bg-[#00ff88]/10",
                        else: "border-[#444] text-[#666] hover:text-[#aaa]")}
                  >
                    {if @bot_chat_status[:topic_injection_enabled], do: "AUTO ON", else: "AUTO OFF"}
                  </button>
                  <button
                    phx-click="inject_topic_now"
                    phx-target={@myself}
                    class="px-3 py-0.5 border border-[#aa66ff]/50 text-[#aa66ff] text-[9px] tracking-widest hover:bg-[#aa66ff]/10"
                  >
                    INJECT NOW
                  </button>
                </div>
              </div>
              <form phx-submit="add_custom_topic" phx-target={@myself} class="flex gap-2">
                <input
                  type="text"
                  name="topic"
                  value={@new_topic}
                  placeholder="Add custom topic..."
                  class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#aa66ff] focus:outline-none placeholder:text-[#444]"
                />
                <button
                  type="submit"
                  class="px-3 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[9px] tracking-widest hover:bg-[#aa66ff]/10"
                >
                  ADD
                </button>
              </form>
              <div
                :if={(@bot_chat_status[:custom_topics] || []) != []}
                class="mt-2 flex flex-wrap gap-1"
              >
                <span
                  :for={topic <- @bot_chat_status[:custom_topics] || []}
                  class="inline-flex items-center gap-1 px-2 py-0.5 bg-[#111] border border-[#333] text-[10px] text-[#aaa]"
                >
                  {String.slice(topic, 0, 40)}{if String.length(topic) > 40, do: "..."}
                  <button
                    phx-click="remove_custom_topic"
                    phx-target={@myself}
                    phx-value-topic={topic}
                    class="text-[#ff4444]/50 hover:text-[#ff4444] text-[8px]"
                  >
                    x
                  </button>
                </span>
              </div>
            </div>

            <%!-- Active pairs --%>
            <div :if={map_size(@bot_chat_status[:pairs] || %{}) > 0} class="border border-[#222] p-3">
              <div class="text-[9px] tracking-widest text-[#888] mb-2">ACTIVE CONVERSATIONS</div>
              <div class="space-y-1">
                <div
                  :for={{{a, b}, pair} <- @bot_chat_status[:pairs] || %{}}
                  class="flex items-center justify-between text-[10px]"
                >
                  <span>
                    <span class="text-[#00ffff]">{a}</span>
                    <span class="text-[#555]">↔</span>
                    <span class="text-[#00ffff]">{b}</span>
                  </span>
                  <span class="text-[#888]">
                    {pair.count}/{get_in(@bot_chat_status, [:config, :max_exchanges]) || 3}
                    <%= if pair[:cooldown_until] do %>
                      <span class="text-[#ff4444] ml-1">COOLDOWN</span>
                    <% end %>
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Commands reference --%>
      <div class="border border-[#222] bg-[#0d0d14] p-4">
        <div class="text-[10px] tracking-widest text-[#666] mb-2">COMMAND REFERENCE</div>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-x-6 gap-y-1 text-[11px]">
          <div>
            <span class="text-[#00ffff]">!ask</span>
            <span class="text-[#666]">&lt;question&gt;</span>
          </div>
          <div>
            <span class="text-[#00ffff]">/msg Bot</span>
            <span class="text-[#666]">&lt;text&gt;</span>
          </div>
          <div>
            <span class="text-[#00ffff]">!models</span>
            <span class="text-[#666]">list models</span>
          </div>
          <div>
            <span class="text-[#00ffff]">!model</span> <span class="text-[#666]">&lt;id&gt;</span>
          </div>
          <div>
            <span class="text-[#00ffff]">!personality</span>
            <span class="text-[#666]">&lt;text&gt;</span>
          </div>
          <div>
            <span class="text-[#00ffff]">!reset</span>
            <span class="text-[#666]">clear history</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Deploy Config Events ---

  @impl true
  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model)}
  end

  def handle_event("select_preset", %{"preset" => "custom"}, socket) do
    {:noreply, assign(socket, selected_preset: nil, deploy_personality: default_personality())}
  end

  def handle_event("select_preset", %{"preset" => preset_id}, socket) do
    preset_atom =
      try do
        String.to_existing_atom(preset_id)
      rescue
        ArgumentError -> nil
      end

    case preset_atom && McFun.Presets.get(preset_atom) do
      {:ok, preset} ->
        combined =
          String.trim(default_personality()) <> "\n\n" <> String.trim(preset.system_prompt)

        {:noreply, assign(socket, selected_preset: preset_id, deploy_personality: combined)}

      _ ->
        notify_parent(socket, {:flash, :error, "Preset not found: #{preset_id}"})
        {:noreply, socket}
    end
  end

  def handle_event("update_deploy_personality", %{"personality" => p}, socket) do
    {:noreply, assign(socket, deploy_personality: p)}
  end

  def handle_event("bot_name_input", %{"name" => val}, socket) do
    {:noreply, assign(socket, bot_spawn_name: val)}
  end

  # --- Bot Deploy ---

  def handle_event("deploy_bot", %{"name" => name}, socket) when name != "" do
    model = socket.assigns.selected_model
    personality = socket.assigns.deploy_personality

    if name in socket.assigns.bots do
      ensure_chatbot(name, model, personality)
      notify_parent(socket, {:flash, :info, "#{name} already running — model: #{model}"})
      notify_parent(socket, :refresh_bot_statuses)
      {:noreply, socket}
    else
      spawn_new_bot(socket, name, model, personality)
    end
  end

  def handle_event("deploy_bot", _, socket), do: {:noreply, socket}

  # --- Failed Bot Actions ---

  def handle_event("whitelist_and_deploy", %{"name" => name}, socket) do
    Task.start(fn ->
      parent = socket.assigns.parent_pid

      msg =
        case McFun.Rcon.command("whitelist add #{name}") do
          {:ok, reply} -> reply
          {:error, reason} -> "Failed: #{inspect(reason)}"
        end

      send(parent, {:flash, :info, "Whitelist: #{msg}"})
      send(parent, {:clear_failed, name})
    end)

    # Re-deploy after a short delay for whitelist to take effect
    model = socket.assigns.selected_model
    personality = socket.assigns.deploy_personality

    Task.start(fn ->
      Process.sleep(500)
      parent = socket.assigns.parent_pid

      case McFun.BotSupervisor.spawn_bot(name) do
        {:ok, _pid} ->
          Process.sleep(2_000)
          ensure_chatbot(name, model, personality)
          send(parent, {:flash, :info, "#{name} deployed after whitelist"})
          send(parent, :refresh_bots)

        {:error, reason} ->
          send(parent, {:flash, :error, "Deploy failed: #{inspect(reason)}"})
      end
    end)

    {:noreply, socket}
  end

  def handle_event("dismiss_failed", %{"name" => name}, socket) do
    notify_parent(socket, {:clear_failed, name})
    {:noreply, socket}
  end

  # --- Bot Interaction Panel ---

  def handle_event("toggle_interaction_panel", _params, socket) do
    {:noreply, assign(socket, interaction_open: !socket.assigns.interaction_open)}
  end

  # --- Bot Chat Controls ---

  def handle_event("toggle_bot_chat", _params, socket) do
    if socket.assigns.bot_chat_status[:enabled] do
      McFun.BotChat.disable()
    else
      McFun.BotChat.enable()
    end

    {:noreply, assign(socket, bot_chat_status: McFun.BotChat.status())}
  end

  def handle_event("update_bot_chat_config", params, socket) do
    if val = params["proximity"] do
      McFun.BotChat.update_config(:proximity, parse_int(val))
    end

    if val = params["max_exchanges"] do
      McFun.BotChat.update_config(:max_exchanges, parse_int(val))
    end

    if val = params["cooldown_s"] do
      McFun.BotChat.update_config(:cooldown_ms, parse_int(val) * 1000)
    end

    if val = params["chance_pct"] do
      McFun.BotChat.update_config(:response_chance, parse_int(val) / 100)
    end

    {:noreply, assign(socket, bot_chat_status: McFun.BotChat.status())}
  end

  def handle_event("toggle_topic_injection", _params, socket) do
    enabled = socket.assigns.bot_chat_status[:topic_injection_enabled]
    McFun.BotChat.toggle_topic_injection(!enabled)
    {:noreply, assign(socket, bot_chat_status: McFun.BotChat.status())}
  end

  def handle_event("inject_topic_now", _params, socket) do
    McFun.BotChat.inject_topic()
    notify_parent(socket, {:flash, :info, "Topic injected"})
    {:noreply, socket}
  end

  def handle_event("add_custom_topic", %{"topic" => topic}, socket) when topic != "" do
    McFun.BotChat.add_topic(topic)
    {:noreply, assign(socket, bot_chat_status: McFun.BotChat.status(), new_topic: "")}
  end

  def handle_event("add_custom_topic", _, socket), do: {:noreply, socket}

  def handle_event("remove_custom_topic", %{"topic" => topic}, socket) do
    McFun.BotChat.remove_topic(topic)
    {:noreply, assign(socket, bot_chat_status: McFun.BotChat.status())}
  end

  # --- Bot Card Actions ---

  def handle_event("select_card_model", %{"bot" => bot_name, "model" => model}, socket) do
    current = get_in(socket.assigns, [:bot_statuses, bot_name, :model])
    pending = if model == current, do: nil, else: model
    pending_models = Map.put(socket.assigns.pending_card_models, bot_name, pending)
    {:noreply, assign(socket, pending_card_models: pending_models)}
  end

  def handle_event("apply_card_model", %{"bot" => bot_name}, socket) do
    model = socket.assigns.pending_card_models[bot_name]

    if model do
      McFun.ChatBot.set_model(bot_name, model)
      pending_models = Map.delete(socket.assigns.pending_card_models, bot_name)
      notify_parent(socket, {:flash, :info, "#{bot_name} >> #{model}"})
      notify_parent(socket, :refresh_bot_statuses)
      {:noreply, assign(socket, pending_card_models: pending_models)}
    else
      {:noreply, socket}
    end
  catch
    _, _ ->
      notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot_name}"})
      {:noreply, socket}
  end

  def handle_event("attach_chatbot", %{"bot" => name}, socket) do
    model = socket.assigns.selected_model
    ensure_chatbot(name, model)
    notify_parent(socket, {:flash, :info, "ChatBot >> #{name} [#{model}]"})
    notify_parent(socket, :refresh_bot_statuses)
    {:noreply, socket}
  end

  def handle_event("teleport_bot", %{"bot" => bot, "player" => player}, socket)
      when player != "" do
    McFun.Bot.teleport_to(bot, player)
    notify_parent(socket, {:flash, :info, "#{bot} >> tp to #{player}"})
    {:noreply, socket}
  end

  def handle_event("teleport_bot", _, socket), do: {:noreply, socket}

  def handle_event("toggle_heartbeat", %{"bot" => bot, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    try do
      McFun.ChatBot.toggle_heartbeat(bot, enabled?)
      notify_parent(socket, :refresh_bot_statuses)
    catch
      _, _ ->
        notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot}"})
    end

    {:noreply, socket}
  end

  def handle_event("toggle_group_chat", %{"bot" => bot, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    try do
      McFun.ChatBot.toggle_group_chat(bot, enabled?)
      notify_parent(socket, :refresh_bot_statuses)
    catch
      _, _ ->
        notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot}"})
    end

    {:noreply, socket}
  end

  def handle_event("stop_bot", %{"name" => name}, socket) do
    stop_chatbot(name)
    McFun.BotSupervisor.stop_bot(name)
    notify_parent(socket, :refresh_bots)
    {:noreply, socket}
  end

  # --- Forward to Parent ---

  def handle_event("open_bot_config", %{"bot" => bot}, socket) do
    notify_parent(socket, {:open_bot_config, bot})
    {:noreply, socket}
  end

  def handle_event("use_coords", params, socket) do
    notify_parent(socket, {:use_coords, params})
    {:noreply, socket}
  end

  # --- Helpers ---

  defp notify_parent(socket, message) do
    send(socket.assigns.parent_pid, message)
  end

  defp spawn_new_bot(socket, name, model, personality) do
    case McFun.BotSupervisor.spawn_bot(name) do
      {:ok, pid} ->
        Process.monitor(pid)
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{name}")
        schedule_chatbot_attach(socket, name, model, personality)
        notify_parent(socket, {:flash, :info, "Deploying #{name} [#{model}]..."})
        notify_parent(socket, :refresh_bots)
        {:noreply, assign(socket, bot_spawn_name: "")}

      {:error, reason} ->
        notify_parent(socket, {:flash, :error, "Deploy failed: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  defp schedule_chatbot_attach(socket, name, model, personality) do
    parent = socket.assigns.parent_pid

    Task.start(fn ->
      Process.sleep(2_000)
      ensure_chatbot(name, model, personality)
      send(parent, :refresh_bots)
    end)
  end

  defp ensure_chatbot(name, model, personality \\ nil) do
    opts = [bot_name: name, model: model]
    opts = if personality, do: Keyword.put(opts, :personality, personality), else: opts
    spec = {McFun.ChatBot, opts}

    case DynamicSupervisor.start_child(McFun.BotSupervisor, spec) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        try do
          McFun.ChatBot.set_model(name, model)
          if personality, do: McFun.ChatBot.set_personality(name, personality)
        catch
          _, _ -> :ok
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_chatbot(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end

  defp default_personality do
    Application.get_env(:mc_fun, :chat_bot)[:default_personality]
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(_), do: 0
end
