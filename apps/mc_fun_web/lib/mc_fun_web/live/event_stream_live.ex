defmodule McFunWeb.EventStreamLive do
  @moduledoc "Event stream LiveComponent — real-time event log display."
  use McFunWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="panel-events"
      role="tabpanel"
      class="border-2 border-[#333]/50 bg-[#0d0d14]"
    >
      <div class="flex items-center justify-between px-4 pt-3 pb-2">
        <div class="text-[10px] tracking-widest text-[#888]">
          EVENT STREAM <span class="text-[#00ffff]">[{length(@events)}]</span>
        </div>
        <div class="flex items-center gap-1">
          <div class="w-1.5 h-1.5 rounded-full bg-[#00ff88] animate-pulse" />
          <span class="text-[10px] text-[#00ff88]">LIVE</span>
        </div>
      </div>
      <div class="bg-[#080810] mx-2 mb-2 h-96 overflow-y-auto p-3 text-[11px] border border-[#222]">
        <div
          :for={{event, idx} <- Enum.with_index(@events)}
          id={"event-#{idx}"}
          class="mb-0.5 flex gap-2"
        >
          <span class="text-[#444] shrink-0">{Calendar.strftime(event.at, "%H:%M:%S")}</span>
          <span class={"shrink-0 " <> event_color(event.type)}>[{event.type}]</span>
          <span class="text-[#888]">{format_event_data(event.data)}</span>
        </div>
        <div :if={@events == []} class="text-[#333]">waiting for events...</div>
      </div>
    </div>
    """
  end

  # --- Render Helpers ---

  defp event_color(:player_join), do: "text-[#00ff88]"
  defp event_color(:player_leave), do: "text-[#ffaa00]"
  defp event_color(:player_death), do: "text-[#ff4444]"
  defp event_color(:player_chat), do: "text-[#00ffff]"
  defp event_color(:player_advancement), do: "text-[#aa66ff]"
  defp event_color(:bot_chat), do: "text-[#00ffff]"
  defp event_color(:bot_whisper), do: "text-[#ff66aa]"
  defp event_color(:bot_spawn), do: "text-[#00ff88]"
  defp event_color(:bot_llm_response), do: "text-[#ffcc00]"
  defp event_color(_), do: "text-[#666]"

  defp format_event_data(data) when is_map(data) do
    data
    |> Map.drop([:raw_line, :timestamp])
    |> Map.drop(["raw_line", "timestamp"])
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp format_event_data(data), do: inspect(data)

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp format_value(v) when is_map(v), do: inspect(v)
  defp format_value(v) when is_list(v), do: inspect(v)
  defp format_value(v), do: to_string(v)
end
