defmodule Mix.Tasks.Mc.Bot.Spawn do
  @moduledoc "Spawn a mineflayer bot: mix mc.bot.spawn BotName"
  @shortdoc "Spawn a mineflayer bot"
  use Mix.Task

  @impl true
  def run([name | _]) do
    Mix.Task.run("app.start")

    case apply(McFun.BotSupervisor, :spawn_bot, [name]) do
      {:ok, _pid} ->
        Mix.shell().info("Bot #{name} spawned. Press Ctrl+C to stop.")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.shell().error("Failed to spawn bot: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.bot.spawn <name>")
end

defmodule Mix.Tasks.Mc.Bot.Chat do
  @moduledoc "Send chat as bot: mix mc.bot.chat BotName Hello!"
  @shortdoc "Send chat message as bot"
  use Mix.Task

  @impl true
  def run([name | words]) when words != [] do
    Mix.Task.run("app.start")
    message = Enum.join(words, " ")

    case apply(McFun.BotSupervisor, :spawn_bot, [name]) do
      {:ok, _pid} ->
        Process.sleep(3_000)
        apply(McFun.Bot, :chat, [name, message])
        Process.sleep(1_000)
        apply(McFun.BotSupervisor, :stop_bot, [name])

      {:error, {:already_started, _}} ->
        apply(McFun.Bot, :chat, [name, message])
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix mc.bot.chat <name> <message>")
end
