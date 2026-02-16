defmodule McFun.Redstone.Executor do
  @moduledoc """
  Stateless module that builds and executes RCON commands for
  redstone circuit placement, activation, and removal.
  """
  require Logger

  @command_delay 50

  @doc "Place all blocks of a circuit in the world via RCON."
  @spec place_circuit(map()) :: :ok | {:error, term()}
  def place_circuit(%{origin: origin, blocks: blocks}) do
    Enum.each(blocks, fn block_def ->
      abs = absolute_pos(origin, block_def.pos)
      cmd = build_setblock_cmd(abs, block_def)
      rcon(cmd)
      Process.sleep(@command_delay)
    end)

    :ok
  end

  @doc "Activate a circuit by placing a redstone block at its trigger position."
  @spec activate(map()) :: :ok | {:error, term()}
  def activate(%{origin: origin, trigger: trigger}) do
    abs = absolute_pos(origin, trigger)
    rcon("setblock #{coord(abs)} minecraft:redstone_block")
  end

  @doc "Deactivate a circuit by replacing the trigger with air."
  @spec deactivate(map()) :: :ok | {:error, term()}
  def deactivate(%{origin: origin, trigger: trigger}) do
    abs = absolute_pos(origin, trigger)
    rcon("setblock #{coord(abs)} minecraft:air replace")
  end

  @doc "Remove all blocks of a circuit (replace with air)."
  @spec remove_circuit(map()) :: :ok | {:error, term()}
  def remove_circuit(%{origin: origin, blocks: blocks}) do
    Enum.each(blocks, fn block_def ->
      abs = absolute_pos(origin, block_def.pos)
      rcon("setblock #{coord(abs)} minecraft:air replace")
      Process.sleep(@command_delay)
    end)

    :ok
  end

  @doc "Fill a rectangular region with a block."
  @spec fill(map(), map(), String.t()) :: :ok | {:error, term()}
  def fill(pos1, pos2, block) do
    rcon("fill #{coord(pos1)} #{coord(pos2)} minecraft:#{block}")
  end

  # Command builders

  defp build_setblock_cmd(abs, %{block: "command_block"} = block_def) do
    facing = Map.get(block_def, :facing, "north")
    command = Map.get(block_def, :command, "")
    auto = if Map.get(block_def, :auto, false), do: "1b", else: "0b"

    escaped_command = String.replace(command, ~s("), ~s(\\"))

    "setblock #{coord(abs)} minecraft:command_block[facing=#{facing}]{Command:\"#{escaped_command}\",auto:#{auto}}"
  end

  defp build_setblock_cmd(abs, %{block: "chain_command_block"} = block_def) do
    facing = Map.get(block_def, :facing, "north")
    command = Map.get(block_def, :command, "")
    auto = if Map.get(block_def, :auto, true), do: "1b", else: "0b"

    escaped_command = String.replace(command, ~s("), ~s(\\"))

    "setblock #{coord(abs)} minecraft:chain_command_block[facing=#{facing}]{Command:\"#{escaped_command}\",auto:#{auto}}"
  end

  defp build_setblock_cmd(abs, %{block: block}) do
    "setblock #{coord(abs)} minecraft:#{block}"
  end

  # Helpers

  defp absolute_pos(origin, relative) do
    %{
      x: Map.get(origin, :x, 0) + Map.get(relative, :x, 0),
      y: Map.get(origin, :y, 0) + Map.get(relative, :y, 0),
      z: Map.get(origin, :z, 0) + Map.get(relative, :z, 0)
    }
  end

  defp coord(%{x: x, y: y, z: z}), do: "#{x} #{y} #{z}"

  defp rcon(cmd) do
    case McFun.Rcon.command(cmd) do
      {:ok, _} -> :ok
      {:error, reason} = err ->
        Logger.warning("Redstone RCON error: #{inspect(reason)} — cmd: #{cmd}")
        err
    end
  end
end
