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
     |> assign_new(:pending_card_models, fn -> %{} end)}
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
    "You are a friendly Minecraft bot. Keep responses to 1-2 sentences. No markdown."
  end
end
