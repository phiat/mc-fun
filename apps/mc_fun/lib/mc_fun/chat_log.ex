defmodule McFun.ChatLog do
  @moduledoc """
  Persistent chat log GenServer.

  Subscribes to game events and bot PubSub topics, classifies messages by type,
  maintains a ring buffer of 500 entries, and persists to JSONL on disk.
  Broadcasts {:new_chat_entry, entry} on the "chat_log" PubSub topic.
  """

  use GenServer
  require Logger

  @max_entries 500
  @refresh_interval_ms 5_000
  @log_file Application.app_dir(:mc_fun, "priv/chat_log.jsonl")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all chat entries (newest first)."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "List chat entries filtered by type."
  def list(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc "Clear all entries and truncate log file."
  def clear, do: GenServer.call(__MODULE__, :clear)

  # Server

  @impl true
  def init(_opts) do
    McFun.Events.subscribe(:all)

    # Subscribe to existing bots
    bots = active_bot_names()

    for bot <- bots do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    # Refresh bot subscriptions periodically
    :timer.send_interval(@refresh_interval_ms, :refresh_bots)

    # Load existing entries from JSONL
    {entries, next_id} = load_from_file()

    # Open file for appending
    file = File.open!(@log_file, [:append, :utf8])

    {:ok,
     %{
       entries: entries,
       next_id: next_id,
       subscribed_bots: MapSet.new(bots),
       log_file: file
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call({:list, opts}, _from, state) do
    types = Keyword.get(opts, :types)

    filtered =
      if types do
        Enum.filter(state.entries, &(&1.type in types))
      else
        state.entries
      end

    {:reply, filtered, state}
  end

  def handle_call(:clear, _from, state) do
    File.close(state.log_file)
    File.write!(@log_file, "")
    file = File.open!(@log_file, [:append, :utf8])

    Phoenix.PubSub.broadcast(McFun.PubSub, "chat_log", :chat_log_cleared)

    {:reply, :ok, %{state | entries: [], next_id: 1, log_file: file}}
  end

  # Bot events from PubSub "bot:#{name}"
  # When a bot hears chat, classify it: bot speech is already captured by
  # llm_response/heartbeat events, so skip to avoid duplicates.
  # Player chat is captured by mc_event :player_chat, so also skip.
  @impl true
  def handle_info({:bot_event, _bot_name, %{"event" => "chat"}}, state) do
    {:noreply, state}
  end

  def handle_info({:bot_event, bot_name, %{"event" => "whisper"} = data}, state) do
    username = Map.get(data, "username", "unknown")
    message = Map.get(data, "message", "")

    entry =
      build_entry(state.next_id, username, message, :whisper, bot_name, %{
        "heard_by" => bot_name
      })

    {:noreply, push_entry(state, entry)}
  end

  def handle_info(
        {:bot_event, bot_name, %{"event" => "llm_response", "tools" => "heartbeat"} = data},
        state
      ) do
    message = Map.get(data, "response", "")

    entry =
      build_entry(state.next_id, bot_name, message, :heartbeat, bot_name, %{
        "tools" => "heartbeat"
      })

    {:noreply, push_entry(state, entry)}
  end

  def handle_info({:bot_event, bot_name, %{"event" => "llm_response"} = data}, state) do
    message = Map.get(data, "response", "")
    tools = Map.get(data, "tools")

    metadata =
      if tools do
        %{"tools" => tools}
      else
        %{}
      end

    entry = build_entry(state.next_id, bot_name, message, :llm_response, bot_name, metadata)
    {:noreply, push_entry(state, entry)}
  end

  # MC events from Events system
  def handle_info({:mc_event, :player_chat, data}, state) do
    username = data[:username] || data["username"] || "unknown"
    message = data[:message] || data["message"] || ""

    entry = build_entry(state.next_id, username, message, :player_chat, nil, %{})
    {:noreply, push_entry(state, entry)}
  end

  def handle_info({:mc_event, type, data}, state)
      when type in [:player_join, :player_leave, :player_death] do
    username = data[:username] || data["username"] || "unknown"
    message = format_system_message(type, username, data)

    entry = build_entry(state.next_id, username, message, :system, nil, %{"event" => type})
    {:noreply, push_entry(state, entry)}
  end

  def handle_info(:refresh_bots, state) do
    current_bots = MapSet.new(active_bot_names())
    subscribed = state.subscribed_bots

    for bot <- MapSet.difference(current_bots, subscribed) do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    for bot <- MapSet.difference(subscribed, current_bots) do
      Phoenix.PubSub.unsubscribe(McFun.PubSub, "bot:#{bot}")
    end

    {:noreply, %{state | subscribed_bots: current_bots}}
  end

  # Ignore other events
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    File.close(state.log_file)
    :ok
  end

  # --- Helpers ---

  defp build_entry(id, from, message, type, bot, metadata) do
    %{
      id: id,
      from: from,
      message: message,
      type: type,
      bot: bot,
      metadata: metadata,
      at: DateTime.utc_now()
    }
  end

  defp push_entry(state, entry) do
    # Persist to JSONL
    json = Jason.encode!(%{entry | at: DateTime.to_iso8601(entry.at)})
    IO.write(state.log_file, json <> "\n")

    # Broadcast
    Phoenix.PubSub.broadcast(McFun.PubSub, "chat_log", {:new_chat_entry, entry})

    # Ring buffer
    entries = [entry | Enum.take(state.entries, @max_entries - 1)]

    %{state | entries: entries, next_id: state.next_id + 1}
  end

  defp load_from_file do
    if File.exists?(@log_file) do
      lines =
        @log_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-@max_entries)

      next_id =
        case lines do
          [] -> 1
          _ -> (lines |> Enum.map(& &1.id) |> Enum.max()) + 1
        end

      # Return newest first
      {Enum.reverse(lines), next_id}
    else
      {[], 1}
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, data} ->
        %{
          id: data["id"],
          from: data["from"],
          message: data["message"],
          type: String.to_existing_atom(data["type"]),
          bot: data["bot"],
          metadata: data["metadata"] || %{},
          at: parse_datetime(data["at"])
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()

  defp format_system_message(:player_join, username, _), do: "#{username} joined the game"
  defp format_system_message(:player_leave, username, _), do: "#{username} left the game"

  defp format_system_message(:player_death, username, data) do
    cause = data[:message] || data["message"] || "died"
    "#{username}: #{cause}"
  end

  defp active_bot_names do
    # Runtime lookup — BotSupervisor lives in bot_farmer app (no compile-time dep)
    Registry.select(McFun.BotRegistry, [{{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}])
  rescue
    _ -> []
  end
end
