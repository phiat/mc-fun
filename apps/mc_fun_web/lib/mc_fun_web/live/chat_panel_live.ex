defmodule McFunWeb.ChatPanelLive do
  @moduledoc "Chat panel LiveComponent — color-coded message viewer with filters."
  use McFunWeb, :live_component

  @bot_colors ~w(#00ffcc #ff66aa #aa66ff #ffcc00 #00ff88 #66aaff)

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:show_heartbeats, fn -> false end)
      |> assign_new(:show_whispers, fn -> true end)
      |> assign_new(:show_bot_chat, fn -> true end)
      |> assign_new(:show_system, fn -> true end)
      |> assign_new(:at_bottom, fn -> true end)

    {:ok, assign(socket, filtered_entries: filter_entries(socket))}
  end

  @impl true
  def handle_event("toggle_filter", %{"filter" => filter}, socket) do
    key =
      case filter do
        "heartbeats" -> :show_heartbeats
        "whispers" -> :show_whispers
        "bot_chat" -> :show_bot_chat
        "system" -> :show_system
      end

    socket = assign(socket, key, !Map.get(socket.assigns, key))
    {:noreply, assign(socket, filtered_entries: filter_entries(socket))}
  end

  def handle_event("scroll_state_changed", %{"at_bottom" => at_bottom}, socket) do
    {:noreply, assign(socket, at_bottom: at_bottom)}
  end

  def handle_event("scroll_to_bottom", _params, socket) do
    {:noreply, assign(socket, at_bottom: true)}
  end

  def handle_event("clear_chat", _params, socket) do
    McFun.ChatLog.clear()
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="panel-chat" role="tabpanel" class="border-2 border-[#333]/50 bg-[#0d0d14]">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 pt-3 pb-2">
        <div class="text-[10px] tracking-widest text-[#888]">
          CHAT LOG <span class="text-[#00ffff]">[{length(@filtered_entries)}]</span>
        </div>
        <div class="flex items-center gap-2">
          <button
            :for={
              {key, label, color} <- [
                {"heartbeats", "HEARTBEAT", "#444"},
                {"whispers", "WHISPER", "#ff66aa"},
                {"bot_chat", "BOT", "#aa66ff"},
                {"system", "SYSTEM", "#888"}
              ]
            }
            phx-click="toggle_filter"
            phx-value-filter={key}
            phx-target={@myself}
            class={"px-2 py-0.5 text-[9px] tracking-wider border transition-all " <>
              if(filter_active?(@myself, key, assigns),
                do: "border-[#{color}] text-[#{color}] bg-[#{color}]/10",
                else: "border-[#333] text-[#444] hover:border-[#555]")}
          >
            {label}
          </button>
          <button
            phx-click="clear_chat"
            phx-target={@myself}
            data-confirm="Clear chat log?"
            class="px-2 py-0.5 text-[9px] tracking-wider border border-[#ff4444] text-[#ff4444] hover:bg-[#ff4444]/10 transition-all"
          >
            CLEAR
          </button>
          <div class="flex items-center gap-1">
            <div class="w-1.5 h-1.5 rounded-full bg-[#00ff88] animate-pulse" />
            <span class="text-[10px] text-[#00ff88]">LIVE</span>
          </div>
        </div>
      </div>

      <%!-- Chat messages --%>
      <div
        id="chat-scroll-container"
        phx-hook="ChatScroll"
        class="bg-[#080810] mx-2 mb-2 h-[32rem] overflow-y-auto p-3 text-[11px] border border-[#222] space-y-1.5"
      >
        <div :if={@filtered_entries == []} class="text-center py-16 text-[#333] text-xs">
          waiting for messages...
        </div>

        <div
          :for={entry <- Enum.reverse(@filtered_entries)}
          id={"chat-#{entry.id}"}
          class="animate-fade-in"
        >
          <%= cond do %>
            <% entry.type == :system -> %>
              <.system_message entry={entry} />
            <% entry.type in [:llm_response, :heartbeat, :bot_to_bot] -> %>
              <.bot_message entry={entry} />
            <% true -> %>
              <.player_message entry={entry} />
          <% end %>
        </div>
      </div>

      <%!-- New messages indicator --%>
      <div
        :if={!@at_bottom && @filtered_entries != []}
        class="absolute bottom-4 left-1/2 -translate-x-1/2 z-10"
      >
        <button
          phx-click="scroll_to_bottom"
          phx-target={@myself}
          class="px-3 py-1 text-[10px] tracking-widest bg-[#00ffff]/20 border border-[#00ffff] text-[#00ffff] hover:bg-[#00ffff]/30 transition-all"
        >
          NEW MESSAGES ↓
        </button>
      </div>
    </div>
    """
  end

  # --- Function Components ---

  defp player_message(assigns) do
    border_color =
      case assigns.entry.type do
        :whisper -> "border-[#ff66aa]"
        _ -> "border-[#00ffff]"
      end

    opacity = if assigns.entry.type == :whisper, do: "opacity-70", else: ""
    avatar_color = avatar_color_for(assigns.entry.from)

    assigns =
      assigns
      |> assign(:border_color, border_color)
      |> assign(:opacity, opacity)
      |> assign(:avatar_color, avatar_color)

    ~H"""
    <div class={"flex items-start gap-2 #{@opacity}"}>
      <div class={"w-6 h-6 flex items-center justify-center text-[10px] font-bold shrink-0 border #{@avatar_color}"}>
        {String.first(@entry.from)}
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-0.5">
          <span class="text-[#e0e0e0] text-[10px] font-bold">{@entry.from}</span>
          <span :if={@entry.type == :whisper} class="text-[9px] text-[#ff66aa]">WHISPER</span>
          <span class="text-[9px] text-[#444]">{format_relative_time(@entry.at)}</span>
        </div>
        <div class={"border-l-2 #{@border_color} pl-2 text-[#ccc]"}>
          {@entry.message}
        </div>
      </div>
    </div>
    """
  end

  defp bot_message(assigns) do
    border_color =
      case assigns.entry.type do
        :heartbeat -> "border-[#444]"
        _ -> "border-[#aa66ff]"
      end

    extra_classes =
      case assigns.entry.type do
        :heartbeat -> "opacity-50 text-[10px]"
        _ -> ""
      end

    avatar_color = avatar_color_for(assigns.entry.from)
    tools = (assigns.entry.metadata || %{})["tools"]

    assigns =
      assigns
      |> assign(:border_color, border_color)
      |> assign(:extra_classes, extra_classes)
      |> assign(:avatar_color, avatar_color)
      |> assign(:tools, tools)

    ~H"""
    <div class={"flex items-start gap-2 justify-end #{@extra_classes}"}>
      <div class="flex-1 min-w-0 text-right">
        <div class="flex items-center gap-2 justify-end mb-0.5">
          <span class="text-[9px] text-[#444]">{format_relative_time(@entry.at)}</span>
          <span :if={@entry.type == :heartbeat} class="text-[9px] text-[#444]">HEARTBEAT</span>
          <span :if={@entry.type == :bot_to_bot} class="text-[9px] text-[#aa66ff]">BOT↔BOT</span>
          <span :if={@entry.type == :llm_response} class="text-[9px] text-[#aa66ff]">BOT</span>
          <span class="text-[#ffcc00] text-[10px] font-bold">{@entry.from}</span>
        </div>
        <div class={"border-r-2 #{@border_color} pr-2 text-[#ccc] text-right"}>
          {@entry.message}
        </div>
        <div :if={@tools && @tools != "heartbeat"} class="text-[9px] text-[#666] mt-0.5 text-right">
          [{@tools}]
        </div>
      </div>
      <div class={"w-6 h-6 flex items-center justify-center text-[10px] font-bold shrink-0 border #{@avatar_color}"}>
        B
      </div>
    </div>
    """
  end

  defp system_message(assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-0.5">
      <div class="flex-1 border-t border-[#333]" />
      <span class="text-[9px] text-[#666] whitespace-nowrap">{@entry.message}</span>
      <div class="flex-1 border-t border-[#333]" />
    </div>
    """
  end

  # --- Helpers ---

  defp filter_entries(socket) do
    assigns = socket.assigns
    entries = assigns.chat_entries || []

    Enum.filter(entries, fn entry ->
      case entry.type do
        :heartbeat -> assigns.show_heartbeats
        :whisper -> assigns.show_whispers
        :llm_response -> assigns.show_bot_chat
        :bot_to_bot -> assigns.show_bot_chat
        :system -> assigns.show_system
        _ -> true
      end
    end)
  end

  defp filter_active?(_myself, key, assigns) do
    case key do
      "heartbeats" -> assigns.show_heartbeats
      "whispers" -> assigns.show_whispers
      "bot_chat" -> assigns.show_bot_chat
      "system" -> assigns.show_system
    end
  end

  defp avatar_color_for(name) when is_binary(name) do
    idx = :erlang.phash2(name, length(@bot_colors))
    color = Enum.at(@bot_colors, idx)
    "bg-[#{color}]/20 border-[#{color}] text-[#{color}]"
  end

  defp avatar_color_for(_), do: "bg-[#666]/20 border-[#666] text-[#666]"

  defp format_relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86_400)}d"
    end
  end
end
