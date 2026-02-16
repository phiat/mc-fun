defmodule McFunWeb.RconConsoleLive do
  @moduledoc "RCON console LiveComponent — terminal, quick commands, history."
  use McFunWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:rcon_input, fn -> "" end)
     |> assign_new(:rcon_history, fn -> [] end)
     |> assign_new(:rcon_quick_open, fn -> false end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="panel-rcon"
      role="tabpanel"
      class="border-2 border-[#333]/50 bg-[#0d0d14]"
    >
      <div class="text-[10px] tracking-widest text-[#888] px-4 pt-3 pb-2">RCON TERMINAL</div>
      <div class="bg-[#080810] mx-2 mb-2 h-96 overflow-y-auto p-3 text-xs flex flex-col-reverse border border-[#222]">
        <div :for={{entry, idx} <- Enum.with_index(@rcon_history)} id={"rcon-#{idx}"} class="mb-2">
          <div class="text-[#00ffff]">&gt; {entry.cmd}</div>
          <div class="text-[#888] whitespace-pre-wrap">{entry.result}</div>
        </div>
        <div :if={@rcon_history == []} class="text-[#333]">awaiting input...</div>
      </div>
      <form
        phx-submit="rcon_submit"
        phx-target={@myself}
        id="rcon-form"
        phx-hook="RconConsole"
        class="flex gap-2 px-4 pb-4"
      >
        <input
          type="text"
          name="command"
          value={@rcon_input}
          phx-change="rcon_input"
          phx-target={@myself}
          phx-debounce="blur"
          placeholder="enter rcon command... (↑↓ history, Tab repeat)"
          class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
          autocomplete="off"
        />
        <button
          type="submit"
          phx-disable-with="..."
          class="px-4 py-2 border border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10"
        >
          EXEC
        </button>
      </form>

      <%!-- Quick Commands Toggle --%>
      <div class="px-4 pb-2">
        <button
          phx-click="toggle_rcon_quick"
          phx-target={@myself}
          class="text-[10px] tracking-widest text-[#666] hover:text-[#00ffff] transition-colors"
        >
          {if @rcon_quick_open, do: "[-]", else: "[+]"} QUICK COMMANDS
        </button>
      </div>

      <%!-- Quick Commands Palette --%>
      <div
        :if={@rcon_quick_open}
        id="rcon-quick-cmds"
        phx-hook="QuickCommands"
        class="px-4 pb-4 space-y-2"
      >
        <% entity_opts = entity_options(@bots, @player_statuses) %>

        <%!-- SAY --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="say" />
          <div class="flex-1">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">MESSAGE</label>
            <input
              type="text"
              name="message"
              placeholder="broadcast..."
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
            />
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
          >
            SAY
          </button>
        </form>

        <%!-- GIVE --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="give" />
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">PLAYER</label>
            <select
              name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <div class="flex-1">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">ITEM</label>
            <input
              type="text"
              name="item"
              placeholder="diamond"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
            />
          </div>
          <div class="w-16">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">QTY</label>
            <input
              type="text"
              name="count"
              value="1"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            />
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
          >
            GIVE
          </button>
        </form>

        <%!-- TP (coords) --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="tp_coords" />
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">WHO</label>
            <select
              name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <div :for={{label, name} <- [{"X", "x"}, {"Y", "y"}, {"Z", "z"}]} class="w-16">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">{label}</label>
            <input
              type="text"
              name={name}
              value="0"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            />
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
          >
            TP XYZ
          </button>
        </form>

        <%!-- TP (to entity) --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="tp_entity" />
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">WHO</label>
            <select
              name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">TO</label>
            <select
              name="destination"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
          >
            TP TO
          </button>
        </form>

        <%!-- TIME + WEATHER + GAMEMODE row --%>
        <div class="flex gap-2">
          <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
            <input type="hidden" name="cmd" value="time" />
            <div>
              <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">TIME</label>
              <select
                name="value"
                class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
              >
                <option :for={v <- ["day", "night", "noon", "midnight"]} value={v}>
                  {String.upcase(v)}
                </option>
              </select>
            </div>
            <button
              type="submit"
              class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
            >
              SET
            </button>
          </form>

          <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
            <input type="hidden" name="cmd" value="weather" />
            <div>
              <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">WEATHER</label>
              <select
                name="value"
                class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
              >
                <option :for={v <- ["clear", "rain", "thunder"]} value={v}>
                  {String.upcase(v)}
                </option>
              </select>
            </div>
            <button
              type="submit"
              class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
            >
              SET
            </button>
          </form>

          <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
            <input type="hidden" name="cmd" value="gamemode" />
            <div>
              <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">MODE</label>
              <select
                name="mode"
                class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
              >
                <option :for={v <- ["survival", "creative", "spectator", "adventure"]} value={v}>
                  {String.upcase(v)}
                </option>
              </select>
            </div>
            <div>
              <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">PLAYER</label>
              <select
                name="target"
                class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
              >
                <option :for={opt <- entity_opts} value={opt}>{opt}</option>
              </select>
            </div>
            <button
              type="submit"
              class="px-3 py-1 border border-[#00ffff]/40 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10 shrink-0"
            >
              SET
            </button>
          </form>
        </div>

        <%!-- EFFECT --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="effect" />
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">PLAYER</label>
            <select
              name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <div class="flex-1">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">EFFECT</label>
            <input
              type="text"
              name="effect"
              placeholder="speed"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
            />
          </div>
          <div class="w-14">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">DUR</label>
            <input
              type="text"
              name="duration"
              value="30"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            />
          </div>
          <div class="w-14">
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">AMP</label>
            <input
              type="text"
              name="amplifier"
              value="0"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            />
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#aa66ff]/40 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10 shrink-0"
          >
            EFFECT
          </button>
        </form>

        <%!-- HEAL --%>
        <form phx-submit="rcon_quick" phx-target={@myself} class="flex items-end gap-2">
          <input type="hidden" name="cmd" value="heal" />
          <div>
            <label class="text-[9px] tracking-widest text-[#555] block mb-0.5">PLAYER</label>
            <select
              name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={opt <- entity_opts} value={opt}>{opt}</option>
            </select>
          </div>
          <button
            type="submit"
            class="px-3 py-1 border border-[#00ff88]/40 text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10 shrink-0"
          >
            HEAL
          </button>
        </form>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("rcon_submit", %{"command" => cmd}, socket) when cmd != "" do
    lv = socket.assigns.parent_pid

    Task.start(fn ->
      result =
        case McFun.Rcon.command(cmd) do
          {:ok, response} -> response
          {:error, reason} -> "ERR: #{inspect(reason)}"
        end

      send(lv, {:rcon_result, cmd, result})
    end)

    {:noreply, assign(socket, rcon_input: "")}
  end

  def handle_event("rcon_submit", _, socket), do: {:noreply, socket}

  def handle_event("rcon_input", %{"command" => val}, socket) do
    {:noreply, assign(socket, rcon_input: val)}
  end

  def handle_event("toggle_rcon_quick", _params, socket) do
    {:noreply, assign(socket, rcon_quick_open: !socket.assigns.rcon_quick_open)}
  end

  def handle_event("rcon_quick", %{"cmd" => "say", "message" => msg}, socket) do
    run_rcon(socket, "say #{msg}")
  end

  def handle_event("rcon_quick", %{"cmd" => "give"} = p, socket) do
    count = if p["count"] != "", do: p["count"], else: "1"
    run_rcon(socket, "give #{p["target"]} #{p["item"]} #{count}")
  end

  def handle_event("rcon_quick", %{"cmd" => "tp_coords"} = p, socket) do
    run_rcon(socket, "tp #{p["target"]} #{p["x"]} #{p["y"]} #{p["z"]}")
  end

  def handle_event("rcon_quick", %{"cmd" => "tp_entity"} = p, socket) do
    run_rcon(socket, "tp #{p["target"]} #{p["destination"]}")
  end

  def handle_event("rcon_quick", %{"cmd" => "time", "value" => val}, socket) do
    run_rcon(socket, "time set #{val}")
  end

  def handle_event("rcon_quick", %{"cmd" => "weather", "value" => val}, socket) do
    run_rcon(socket, "weather #{val}")
  end

  def handle_event("rcon_quick", %{"cmd" => "gamemode"} = p, socket) do
    run_rcon(socket, "gamemode #{p["mode"]} #{p["target"]}")
  end

  def handle_event("rcon_quick", %{"cmd" => "effect"} = p, socket) do
    dur = if p["duration"] != "", do: p["duration"], else: "30"
    amp = if p["amplifier"] != "", do: p["amplifier"], else: "0"
    run_rcon(socket, "effect give #{p["target"]} #{p["effect"]} #{dur} #{amp}")
  end

  def handle_event("rcon_quick", %{"cmd" => "heal"} = p, socket) do
    target = p["target"]

    run_rcon_multi(socket, [
      "effect give #{target} instant_health 1 255",
      "effect give #{target} saturation 1 255"
    ])
  end

  def handle_event("rcon_quick", _, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp entity_options(bots, player_statuses) do
    selectors = ["@a", "@p", "@r"]
    players = Map.keys(player_statuses)
    selectors ++ bots ++ (players -- bots)
  end

  defp run_rcon(socket, cmd) do
    lv = socket.assigns.parent_pid

    Task.start(fn ->
      result =
        case McFun.Rcon.command(cmd) do
          {:ok, r} -> r
          {:error, r} -> "ERR: #{inspect(r)}"
        end

      send(lv, {:rcon_result, cmd, result})
    end)

    {:noreply, socket}
  end

  defp run_rcon_multi(socket, commands) do
    lv = socket.assigns.parent_pid

    Task.start(fn ->
      Enum.each(commands, &exec_and_report_rcon(&1, lv))
    end)

    {:noreply, socket}
  end

  defp exec_and_report_rcon(cmd, lv) do
    result =
      case McFun.Rcon.command(cmd) do
        {:ok, r} -> r
        {:error, r} -> "ERR: #{inspect(r)}"
      end

    send(lv, {:rcon_result, cmd, result})
  end
end
