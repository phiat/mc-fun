defmodule Mix.Tasks.Mc.Music.Play do
  @moduledoc "Play a song: mix mc.music.play songs/twinkle.txt [--bpm 120] [--instrument harp]"
  @shortdoc "Play a Minecraft song"
  use Mix.Task

  alias McFun.World.Music

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [bpm: :integer, instrument: :string])

    file = List.first(positional, "songs/twinkle.txt")

    Mix.Task.run("app.start")

    case Music.play(file, opts) do
      :ok -> Mix.shell().info("Done playing.")
      {:error, reason} -> Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Mc.Music.Inline do
  @moduledoc "Play inline notes: mix mc.music.inline \"C4:q D4:q E4:h\""
  @shortdoc "Play inline notes"
  use Mix.Task

  alias McFun.World.Music

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [bpm: :integer, instrument: :string])

    notes = Enum.join(positional, " ")

    Mix.Task.run("app.start")
    Music.play_inline(notes, opts)
    Mix.shell().info("Done.")
  end
end
