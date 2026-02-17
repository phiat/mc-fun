defmodule McFun.Events.Handlers do
  @moduledoc """
  Default event handlers. Call `register_all/0` after the application starts
  to wire up standard event → effect mappings.
  """
  alias McFun.World.Effects

  require Logger

  @doc "Register all default event handlers."
  @spec register_all() :: :ok
  def register_all do
    register_join_welcome()
    register_death_effects()
    register_advancement_fanfare()
    register_event_logger()
    Logger.info("Event handlers registered")
    :ok
  end

  defp register_join_welcome do
    McFun.Events.subscribe(:player_join, fn _type, %{username: username} ->
      Logger.info("Player #{username} joined — triggering welcome")
      Effects.welcome(username)
      McFun.Rcon.command("say Welcome #{username}!")
    end)
  end

  defp register_death_effects do
    McFun.Events.subscribe(:player_death, fn _type, data ->
      username = Map.get(data, :username, "someone")
      cause = Map.get(data, :cause, "unknown")
      Logger.info("Player #{username} died: #{cause}")
      Effects.death_effect(username)
    end)
  end

  defp register_advancement_fanfare do
    McFun.Events.subscribe(:player_advancement, fn _type, data ->
      username = Map.get(data, :username, "someone")
      advancement = Map.get(data, :advancement, "unknown")
      Logger.info("Player #{username} got advancement: #{advancement}")
      Effects.achievement_fanfare(username)
    end)
  end

  defp register_event_logger do
    McFun.Events.subscribe(:all, fn event_type, data ->
      Logger.debug("MC Event: #{event_type} — #{inspect(Map.delete(data, :raw_line))}")
    end)
  end
end
