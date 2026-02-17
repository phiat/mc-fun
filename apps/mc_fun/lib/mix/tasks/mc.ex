defmodule Mix.Tasks.Mc.Cmd do
  @moduledoc "Send an RCON command: mix mc.cmd \"say hello\""
  @shortdoc "Send an RCON command"
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    cmd = Enum.join(args, " ")

    case McFun.Rcon.command(cmd) do
      {:ok, response} ->
        if response != "", do: Mix.shell().info(response)

      {:error, reason} ->
        Mix.shell().error("RCON error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Mc.Players do
  @moduledoc "List online players: mix mc.players"
  @shortdoc "List online players"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case McFun.Rcon.command("list") do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Mc.Give do
  @moduledoc "Give item to player: mix mc.give PlayerName diamond 64"
  @shortdoc "Give item to player"
  use Mix.Task

  @impl true
  def run([player, item | rest]) do
    Mix.Task.run("app.start")
    count = List.first(rest, "1")
    cmd = "give #{player} #{item} #{count}"

    case McFun.Rcon.command(cmd) do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.give <player> <item> [count]")
end

defmodule Mix.Tasks.Mc.Weather do
  @moduledoc "Set weather: mix mc.weather thunder"
  @shortdoc "Set weather"
  use Mix.Task

  @impl true
  def run([weather | rest]) do
    Mix.Task.run("app.start")
    duration = List.first(rest)
    cmd = if duration, do: "weather #{weather} #{duration}", else: "weather #{weather}"

    case McFun.Rcon.command(cmd) do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.weather <clear|rain|thunder> [duration]")
end

defmodule Mix.Tasks.Mc.Say do
  @moduledoc "Broadcast message: mix mc.say Hello world!"
  @shortdoc "Broadcast a chat message"
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    message = Enum.join(args, " ")

    case McFun.Rcon.command("say #{message}") do
      {:ok, _} -> Mix.shell().info("Message sent.")
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Mc.Tp do
  @moduledoc "Teleport player: mix mc.tp Player x y z"
  @shortdoc "Teleport a player"
  use Mix.Task

  @impl true
  def run([player, x, y, z]) do
    Mix.Task.run("app.start")

    case McFun.Rcon.command("tp #{player} #{x} #{y} #{z}") do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.tp <player> <x> <y> <z>")
end

defmodule Mix.Tasks.Mc.Time do
  @moduledoc "Set time: mix mc.time day"
  @shortdoc "Set time of day"
  use Mix.Task

  @impl true
  def run([time | _]) do
    Mix.Task.run("app.start")

    case McFun.Rcon.command("time set #{time}") do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.time <day|night|noon|midnight|NUMBER>")
end

defmodule Mix.Tasks.Mc.Gamemode do
  @moduledoc "Set gamemode: mix mc.gamemode creative @a"
  @shortdoc "Set gamemode"
  use Mix.Task

  @impl true
  def run([mode, target | _]) do
    Mix.Task.run("app.start")

    case McFun.Rcon.command("gamemode #{mode} #{target}") do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_),
    do:
      Mix.shell().error("Usage: mix mc.gamemode <survival|creative|spectator|adventure> <target>")
end

defmodule Mix.Tasks.Mc.Effect do
  @moduledoc "Give effect: mix mc.effect @a speed 30 2"
  @shortdoc "Give effect to player"
  use Mix.Task

  @impl true
  def run([target, effect | rest]) do
    Mix.Task.run("app.start")
    duration = List.first(rest, "30")
    amplifier = Enum.at(rest, 1, "0")

    case McFun.Rcon.command("effect give #{target} #{effect} #{duration} #{amplifier}") do
      {:ok, response} -> Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  def run(_),
    do: Mix.shell().error("Usage: mix mc.effect <target> <effect> [duration] [amplifier]")
end

defmodule Mix.Tasks.Mc.Heal do
  @moduledoc "Full heal + feed: mix mc.heal @a"
  @shortdoc "Heal and feed a player"
  use Mix.Task

  @impl true
  def run([target | _]) do
    Mix.Task.run("app.start")

    rcon("effect give #{target} instant_health 1 255")
    rcon("effect give #{target} saturation 1 255")

    Mix.shell().info("Healed #{target}")
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.heal <target>")

  defp rcon(cmd) do
    case McFun.Rcon.command(cmd) do
      {:ok, response} -> if response != "", do: Mix.shell().info(response)
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Mc.Status do
  @moduledoc "System health check: mix mc.status"
  @shortdoc "Check system health"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    # Wait for LogWatcher's first RCON poll to complete
    Process.sleep(3_000)
    shell = Mix.shell()

    check_rcon(shell)
    check_process(shell, McFun.LogWatcher, "LogWatcher")

    check_process(shell, McFun.EventStore, "EventStore", fn ->
      "#{length(McFun.EventStore.list())} events"
    end)

    check_process(shell, McFun.PubSub, "PubSub")
    check_bots(shell)
  end

  defp check_rcon(shell) do
    case McFun.Rcon.command("list") do
      {:ok, response} ->
        players = McFun.LogWatcher.parse_player_list(response)
        count = length(players)
        names = if count > 0, do: " (#{Enum.join(players, ", ")})", else: ""
        shell.info("[ok] RCON connected")
        shell.info("[ok] Players online: #{count}#{names}")
        if count > 0, do: check_player_data(shell, players)

      {:error, reason} ->
        shell.error("[FAIL] RCON: #{inspect(reason)}")
    end
  end

  defp check_player_data(shell, players) do
    statuses = McFun.LogWatcher.player_statuses()

    for player <- players do
      case Map.get(statuses, player) do
        %{health: h, position: pos} when not is_nil(h) ->
          shell.info("[ok] Player data: #{player} health=#{h}#{format_pos(pos)}")

        _ ->
          shell.info("[!!] Player data: #{player} -- no data available")
      end
    end
  end

  defp check_process(shell, name, label, detail_fn \\ nil) do
    case Process.whereis(name) do
      nil ->
        shell.error("[FAIL] #{label} not running")

      pid ->
        detail = if detail_fn, do: " (#{detail_fn.()})", else: " (pid #{inspect(pid)})"
        shell.info("[ok] #{label} running#{detail}")
    end
  end

  defp check_bots(shell) do
    # Dynamic call — BotSupervisor lives in bot_farmer, not available at compile time
    bots = apply(McFun.BotSupervisor, :list_bots, [])
    shell.info("[ok] BotRegistry: #{length(bots)} bots")
  rescue
    _ -> shell.error("[FAIL] BotRegistry not available")
  end

  defp format_pos({x, y, z}), do: " pos={#{round(x)},#{round(y)},#{round(z)}}"
  defp format_pos(_), do: ""
end

defmodule Mix.Tasks.Mc.Events do
  @moduledoc "Live event watcher: mix mc.events (Ctrl+C to stop)"
  @shortdoc "Watch live events"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    shell = Mix.shell()

    # Subscribe to all event topics
    McFun.Events.subscribe(:all)
    Phoenix.PubSub.subscribe(McFun.PubSub, "player_statuses")

    # Subscribe to known bot topics
    # Dynamic call — BotSupervisor lives in bot_farmer, not available at compile time
    for bot <- apply(McFun.BotSupervisor, :list_bots, []) do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    shell.info("Watching events... (Ctrl+C to stop)\n")
    event_loop(shell)
  end

  defp event_loop(shell) do
    receive do
      {:mc_event, type, data} ->
        ts = format_time()
        shell.info("[#{ts}] [#{type}] #{format_event_data(type, data)}")

      :player_statuses_updated ->
        ts = format_time()
        statuses = McFun.LogWatcher.player_statuses()

        for {player, data} <- statuses do
          parts =
            [
              if(data[:health], do: "health=#{data.health}"),
              if(data[:food], do: "food=#{data.food}"),
              if(data[:dimension], do: "dim=#{data.dimension}")
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")

          shell.info("[#{ts}] [player_statuses] #{player} #{parts}")
        end

      {ref, _} when is_reference(ref) ->
        :ok

      msg ->
        ts = format_time()
        shell.info("[#{ts}] [unknown] #{inspect(msg)}")
    end

    event_loop(shell)
  end

  defp format_time do
    {{_, _, _}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  defp format_event_data(:player_join, %{username: u}), do: "username=#{u}"
  defp format_event_data(:player_leave, %{username: u}), do: "username=#{u}"

  defp format_event_data(:player_chat, %{username: u, message: m}),
    do: "username=#{u} message=\"#{m}\""

  defp format_event_data(:player_death, %{username: u, cause: c}),
    do: "username=#{u} cause=\"#{c}\""

  defp format_event_data(:player_advancement, %{username: u, advancement: a}),
    do: "username=#{u} advancement=\"#{a}\""

  defp format_event_data(_type, data) do
    data
    |> Map.drop([:timestamp, :raw_line])
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end
end
