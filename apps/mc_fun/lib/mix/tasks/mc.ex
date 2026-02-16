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
