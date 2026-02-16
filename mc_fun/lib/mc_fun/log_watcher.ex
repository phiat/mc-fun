defmodule McFun.LogWatcher do
  @moduledoc """
  GenServer that monitors Minecraft server events via RCON polling.

  Since the MC server runs on a remote host (miniwini-1), we can't read the
  log file directly. Instead, we poll via RCON `list` command to detect
  player joins/leaves, and subscribe to bot events for chat.

  Also supports local log file tailing when the file exists.

  ## Configuration

      config :mc_fun, :log_watcher,
        log_path: "./data/logs/latest.log",
        poll_interval: 500
  """
  use GenServer
  require Logger

  @default_poll_interval 2_000

  # MC server log patterns (used when tailing a local log file)
  @patterns [
    {~r/\[Server thread\/INFO\]: (\w+) joined the game/, :player_join, [:username]},
    {~r/\[Server thread\/INFO\]: (\w+) left the game/, :player_leave, [:username]},
    {~r/\[Server thread\/INFO\]: (\w+) (was slain by|was shot by|drowned|fell from|hit the ground|died|burned|blew up|was killed|suffocated|starved|withered)(.*)$/,
     :player_death, [:username, :cause, :details]},
    {~r/\[Server thread\/INFO\]: <(\w+)> (.+)/, :player_chat, [:username, :message]},
    {~r/\[Server thread\/INFO\]: (\w+) has made the advancement \[(.+?)\]/, :player_advancement,
     [:username, :advancement]},
    {~r/\[Server thread\/INFO\]: Done \([\d.]+s\)!/, :server_started, []}
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current online player list."
  def online_players do
    GenServer.call(__MODULE__, :online_players)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    config = Application.get_env(:mc_fun, :log_watcher, [])
    log_path = Keyword.get(config, :log_path)
    poll_interval = Keyword.get(config, :poll_interval, @default_poll_interval)

    state = %{
      log_path: log_path,
      io_device: nil,
      last_size: 0,
      poll_interval: poll_interval,
      mode: :rcon,
      online_players: MapSet.new()
    }

    # Try local log file first, fall back to RCON polling
    state = maybe_open_log_file(state)

    schedule_poll(state.poll_interval)
    Logger.info("LogWatcher started in #{state.mode} mode (poll: #{poll_interval}ms)")

    {:ok, state}
  end

  @impl true
  def handle_call(:online_players, _from, state) do
    {:reply, MapSet.to_list(state.online_players), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case state.mode do
        :rcon -> poll_rcon(state)
        :file -> poll_file(state)
      end

    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # RCON-based polling

  defp poll_rcon(state) do
    case McFun.Rcon.command("list") do
      {:ok, response} ->
        current = parse_player_list(response)
        current_set = MapSet.new(current)
        old_set = state.online_players

        # Detect joins
        for player <- MapSet.difference(current_set, old_set) |> MapSet.to_list() do
          McFun.Events.dispatch(:player_join, %{
            username: player,
            timestamp: DateTime.utc_now()
          })
        end

        # Detect leaves
        for player <- MapSet.difference(old_set, current_set) |> MapSet.to_list() do
          McFun.Events.dispatch(:player_leave, %{
            username: player,
            timestamp: DateTime.utc_now()
          })
        end

        %{state | online_players: current_set}

      {:error, reason} ->
        Logger.debug("LogWatcher RCON poll failed: #{inspect(reason)}")
        state
    end
  end

  defp parse_player_list(response) do
    # Response format: "There are X of a max of Y players online: player1, player2"
    case Regex.run(~r/players online:\s*(.+)$/, response) do
      [_, players_str] ->
        players_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      nil ->
        # "There are 0 of a max of Y players online:"
        []
    end
  end

  # File-based polling (when log file is accessible)

  defp maybe_open_log_file(state) do
    case state.log_path && File.stat(state.log_path) do
      {:ok, %{size: size}} ->
        case File.open(state.log_path, [:read, :utf8]) do
          {:ok, device} ->
            {:ok, _} = :file.position(device, size)
            Logger.info("LogWatcher: tailing local log #{state.log_path}")
            %{state | io_device: device, last_size: size, mode: :file}

          {:error, _} ->
            Logger.info("LogWatcher: can't open #{state.log_path}, using RCON polling")
            state
        end

      _ ->
        Logger.info("LogWatcher: no local log file, using RCON polling")
        state
    end
  end

  defp poll_file(%{io_device: nil} = state) do
    maybe_open_log_file(state)
  end

  defp poll_file(state) do
    case File.stat(state.log_path) do
      {:ok, %{size: current_size}} when current_size < state.last_size ->
        Logger.info("LogWatcher: log rotation detected, reopening")
        if state.io_device, do: File.close(state.io_device)
        maybe_open_log_file(%{state | io_device: nil, last_size: 0})

      {:ok, %{size: current_size}} when current_size > state.last_size ->
        read_new_lines(state, current_size)

      {:ok, _} ->
        state

      {:error, _} ->
        if state.io_device, do: File.close(state.io_device)
        Logger.info("LogWatcher: log file disappeared, switching to RCON mode")
        %{state | io_device: nil, last_size: 0, mode: :rcon}
    end
  end

  defp read_new_lines(state, current_size) do
    case IO.read(state.io_device, :line) do
      :eof ->
        %{state | last_size: current_size}

      {:error, _reason} ->
        %{state | last_size: current_size}

      line when is_binary(line) ->
        line = String.trim_trailing(line)
        if line != "", do: parse_and_dispatch(line)
        read_new_lines(state, current_size)
    end
  end

  defp parse_and_dispatch(line) do
    Enum.find_value(@patterns, fn {regex, event_type, fields} ->
      case Regex.run(regex, line, capture: :all_but_first) do
        nil ->
          nil

        captures ->
          data =
            fields
            |> Enum.zip(captures)
            |> Map.new()
            |> Map.put(:raw_line, line)
            |> Map.put(:timestamp, DateTime.utc_now())

          McFun.Events.dispatch(event_type, data)
          true
      end
    end)
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
