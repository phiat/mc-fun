defmodule McFun.World.Display do
  @moduledoc """
  Block-font display system. Renders text as placed blocks in the Minecraft world.

  ## Usage

      McFun.World.Display.write("HELLO", %{x: 100, y: 80, z: 200})
      McFun.World.Display.write("MC FUN", %{x: 100, y: 80, z: 200}, material: "red_concrete")
      McFun.World.Display.clear(%{x: 100, y: 73, z: 200}, %{width: 40, height: 7})
  """

  alias McFun.World.Display.BlockFont
  require Logger

  @command_delay 50

  @doc """
  Render text and place blocks in the world via RCON.

  Options:
  - `:material` — block type (default "white_concrete")
  - `:spacing` — columns between characters (default 1)
  - `:direction` — `:east` or `:north` (default `:east`)
  """
  @spec write(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def write(text, origin, opts \\ []) do
    blocks = BlockFont.render(text, origin, opts)

    Logger.info("Display: writing #{String.length(text)} chars (#{length(blocks)} blocks)")

    Enum.each(blocks, fn %{pos: pos, block: block} ->
      cmd = "setblock #{pos.x} #{pos.y} #{pos.z} minecraft:#{block}"

      case McFun.Rcon.command(cmd) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Display RCON error: #{inspect(reason)}")
      end

      Process.sleep(@command_delay)
    end)

    :ok
  end

  @doc """
  Clear a rectangular region by filling with air.

  Size should be `%{width: W, height: H}`. The region starts at origin
  and extends width blocks in the X direction and height blocks downward (-Y).
  """
  @spec clear(map(), map(), keyword()) :: :ok | {:error, term()}
  def clear(origin, size, opts \\ []) do
    direction = Keyword.get(opts, :direction, :east)

    x1 = Map.get(origin, :x, 0)
    y1 = Map.get(origin, :y, 0)
    z1 = Map.get(origin, :z, 0)
    w = Map.get(size, :width, 30)
    h = Map.get(size, :height, 7)

    {x2, y2, z2} =
      case direction do
        :east -> {x1 + w - 1, y1 - h + 1, z1}
        :north -> {x1, y1 - h + 1, z1 - w + 1}
      end

    cmd = "fill #{x1} #{y1} #{z1} #{x2} #{y2} #{z2} minecraft:air"

    case McFun.Rcon.command(cmd) do
      {:ok, _} ->
        Logger.info("Display: cleared #{w}x#{h} region")
        :ok

      {:error, reason} ->
        Logger.warning("Display clear error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
