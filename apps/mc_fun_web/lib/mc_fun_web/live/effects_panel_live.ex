defmodule McFunWeb.EffectsPanelLive do
  @moduledoc "Combined FX panel — effects, titles, and block text display."
  use McFunWeb, :live_component

  alias McFun.World.{Effects, Display}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:effect_target, fn -> "@a" end)
     |> assign_new(:display_text, fn -> "" end)
     |> assign_new(:display_x, fn -> "0" end)
     |> assign_new(:display_y, fn -> "80" end)
     |> assign_new(:display_z, fn -> "0" end)
     |> assign_new(:display_block, fn -> "diamond_block" end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="panel-effects" role="tabpanel" class="space-y-4">
      <%!-- Effects Section --%>
      <div class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
        <div class="text-[10px] tracking-widest text-[#888] mb-3">EFFECTS</div>
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

        <%!-- Custom title --%>
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

      <%!-- Block Text Display Section --%>
      <div class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
        <div class="text-[10px] tracking-widest text-[#888] mb-3">BLOCK TEXT DISPLAY</div>
        <form phx-submit="place_text" phx-target={@myself} class="space-y-3">
          <input
            type="text"
            name="text"
            value={@display_text}
            placeholder="text to render..."
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
          />
          <%!-- Entity picker for location --%>
          <div class="flex items-center gap-2">
            <span class="text-[10px] tracking-wider text-[#666]">LOCATION FROM</span>
            <select
              phx-change="pick_display_entity"
              phx-target={@myself}
              name="entity"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option value="">Manual</option>
              <%= for bot <- @bots do %>
                <option value={bot}>{bot}</option>
              <% end %>
              <%= for {name, _data} <- @player_statuses, name not in @bots do %>
                <option value={name}>{name}</option>
              <% end %>
            </select>
          </div>
          <div class="grid grid-cols-4 gap-2">
            <div :for={
              {label, name, val} <- [
                {"X", "x", @display_x},
                {"Y", "y", @display_y},
                {"Z", "z", @display_z},
                {"BLOCK", "block", @display_block}
              ]
            }>
              <label class="text-[10px] tracking-wider text-[#666] block mb-1">{label}</label>
              <input
                type="text"
                name={name}
                value={val}
                class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
              />
            </div>
          </div>
          <button
            type="submit"
            phx-disable-with="RENDERING..."
            class="px-6 py-2 border-2 border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest font-bold hover:bg-[#00ffff] hover:text-[#0a0a0f] transition-all"
          >
            RENDER
          </button>
        </form>
      </div>
    </div>
    """
  end

  # --- Effect Event Handlers ---

  @impl true
  def handle_event("fire_effect", %{"effect" => effect}, socket) do
    target = socket.assigns.effect_target
    parent = socket.assigns.parent_pid

    Task.start(fn ->
      try do
        case effect do
          "celebration" -> Effects.celebration(target)
          "welcome" -> Effects.welcome(target)
          "death" -> Effects.death_effect(target)
          "achievement" -> Effects.achievement_fanfare(target)
          "firework" -> Effects.firework(target)
          _ -> :ok
        end
      rescue
        e -> send(parent, {:flash, :error, "Effect failed: #{Exception.message(e)}"})
      end
    end)

    send(parent, {:flash, :info, "FX #{effect} >> #{target}"})
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
    parent = socket.assigns.parent_pid

    Task.start(fn ->
      try do
        Effects.title(target, title, opts)
      rescue
        e -> send(parent, {:flash, :error, "Title failed: #{Exception.message(e)}"})
      end
    end)

    send(parent, {:flash, :info, "Title >> #{target}: #{title}"})
    {:noreply, socket}
  end

  def handle_event("fire_title", _, socket), do: {:noreply, socket}

  # --- Display Event Handlers ---

  def handle_event("place_text", params, socket) do
    text = Map.get(params, "text", "")
    x = safe_int(Map.get(params, "x", "0"))
    y = safe_int(Map.get(params, "y", "80"))
    z = safe_int(Map.get(params, "z", "0"))
    block = Map.get(params, "block", "diamond_block")

    if text != "" do
      parent = socket.assigns.parent_pid

      Task.start(fn ->
        try do
          Display.write(text, {x, y, z}, block: block)
        rescue
          e -> send(parent, {:flash, :error, "Display failed: #{Exception.message(e)}"})
        end
      end)

      send(parent, {:flash, :info, "Placing '#{text}' at #{x},#{y},#{z}"})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_display_entity", %{"entity" => ""}, socket), do: {:noreply, socket}

  def handle_event("pick_display_entity", %{"entity" => name}, socket) do
    case lookup_entity_position(socket.assigns, name) do
      {x, y, z} ->
        {:noreply,
         assign(socket,
           display_x: to_string(trunc(x)),
           display_y: to_string(trunc(y)),
           display_z: to_string(trunc(z))
         )}

      nil ->
        {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp entity_options(bots, player_statuses) do
    selectors = ["@a", "@p", "@r"]
    players = Map.keys(player_statuses)
    selectors ++ bots ++ (players -- bots)
  end

  defp safe_int(val) when is_integer(val), do: val

  defp safe_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

  defp lookup_entity_position(assigns, name) do
    case get_in(assigns, [:bot_statuses, name, :position]) do
      {_, _, _} = pos ->
        pos

      _ ->
        case get_in(assigns, [:player_statuses, name, :position]) do
          {_, _, _} = pos -> pos
          _ -> nil
        end
    end
  end
end
