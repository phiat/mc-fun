defmodule McFunWeb.EffectsPanelLive do
  @moduledoc "Effects panel LiveComponent — FX tab with effect triggers and title sending."
  use McFunWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:effect_target, fn -> "@a" end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="panel-effects"
      role="tabpanel"
      class="border-2 border-[#333]/50 bg-[#0d0d14] p-4"
    >
      <div class="text-[10px] tracking-widest text-[#888] mb-3">EFFECTS PANEL</div>
      <div class="flex items-center gap-2 mb-4">
        <span class="text-[10px] tracking-wider text-[#666]">TARGET</span>
        <select
          phx-change="pick_effect_target"
          phx-target={@myself}
          name="target"
          class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
        >
          <option
            :for={opt <- entity_options(@bots, @player_statuses)}
            value={opt}
            selected={opt == @effect_target}
          >
            {opt}
          </option>
        </select>
        <input
          type="text"
          value={@effect_target}
          phx-change="set_effect_target"
          phx-target={@myself}
          phx-debounce="300"
          name="target"
          placeholder="or type custom..."
          class="bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs w-40 focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
        />
      </div>
      <div class="flex flex-wrap gap-2">
        <button
          :for={effect <- ["celebration", "welcome", "death", "achievement", "firework"]}
          phx-click="fire_effect"
          phx-target={@myself}
          phx-value-effect={effect}
          phx-disable-with="..."
          class="px-4 py-2 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10 hover:border-[#aa66ff] transition-all"
        >
          {String.upcase(effect)}
        </button>
      </div>

      <%!-- Custom message --%>
      <form phx-submit="fire_title" phx-target={@myself} class="mt-4 flex items-end gap-2">
        <div class="flex-1">
          <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">TITLE</label>
          <input
            type="text"
            name="title"
            placeholder="big text..."
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#aa66ff] focus:outline-none placeholder:text-[#444]"
          />
        </div>
        <div class="flex-1">
          <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">SUBTITLE</label>
          <input
            type="text"
            name="subtitle"
            placeholder="smaller text..."
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#aa66ff] focus:outline-none placeholder:text-[#444]"
          />
        </div>
        <button
          type="submit"
          phx-disable-with="..."
          class="px-4 py-1.5 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10 hover:border-[#aa66ff] transition-all shrink-0"
        >
          SEND
        </button>
      </form>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("fire_effect", %{"effect" => effect}, socket) do
    target = socket.assigns.effect_target

    Task.start(fn ->
      case effect do
        "celebration" -> McFun.Effects.celebration(target)
        "welcome" -> McFun.Effects.welcome(target)
        "death" -> McFun.Effects.death_effect(target)
        "achievement" -> McFun.Effects.achievement_fanfare(target)
        "firework" -> McFun.Effects.firework(target)
        _ -> :ok
      end
    end)

    send(socket.assigns.parent_pid, {:flash, :info, "FX #{effect} >> #{target}"})
    {:noreply, socket}
  end

  def handle_event("set_effect_target", %{"target" => target}, socket) do
    {:noreply, assign(socket, effect_target: target)}
  end

  def handle_event("pick_effect_target", %{"target" => target}, socket) do
    {:noreply, assign(socket, effect_target: target)}
  end

  def handle_event("fire_title", %{"title" => title} = params, socket) when title != "" do
    target = socket.assigns.effect_target
    subtitle = params["subtitle"]
    opts = if subtitle && subtitle != "", do: [subtitle: subtitle], else: []

    Task.start(fn -> McFun.Effects.title(target, title, opts) end)

    send(socket.assigns.parent_pid, {:flash, :info, "Title >> #{target}: #{title}"})
    {:noreply, socket}
  end

  def handle_event("fire_title", _, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp entity_options(bots, player_statuses) do
    selectors = ["@a", "@p", "@r"]
    players = Map.keys(player_statuses)
    selectors ++ bots ++ (players -- bots)
  end
end
