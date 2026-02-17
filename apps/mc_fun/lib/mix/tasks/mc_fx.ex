defmodule Mix.Tasks.Mc.Fx do
  @moduledoc """
  Fire effects and send title messages.

  ## Usage

      mix mc.fx title @a "Hello" "have fun"    # title + subtitle
      mix mc.fx title @a "Hello"                # title only
      mix mc.fx welcome @a                      # welcome effect
      mix mc.fx celebration @a                  # celebration effect
      mix mc.fx death @a                        # death effect
      mix mc.fx achievement @a                  # achievement fanfare
      mix mc.fx firework @a                     # firework
      mix mc.fx sound @a block.note_block.harp  # play sound
      mix mc.fx particle @a flame               # particle effect

  Target can be a player name or selector (@a, @p, @r).
  """
  @shortdoc "Fire effects and title messages"
  use Mix.Task

  alias McFun.World.Effects

  @effects ~w(welcome celebration death achievement firework)

  @impl true
  def run(["title", target, title | rest]) do
    Mix.Task.run("app.start")
    subtitle = List.first(rest)
    opts = if subtitle, do: [subtitle: subtitle], else: []
    Effects.title(target, title, opts)
    Mix.shell().info("Title sent to #{target}")
  end

  def run(["sound", target, sound_name | rest]) do
    Mix.Task.run("app.start")
    pitch = parse_float(List.first(rest), 1.0)
    Effects.sound(sound_name, target, pitch: pitch)
    Mix.shell().info("Sound #{sound_name} >> #{target}")
  end

  def run(["particle", target, particle_type | _rest]) do
    Mix.Task.run("app.start")
    Effects.particle(particle_type, target)
    Mix.shell().info("Particle #{particle_type} >> #{target}")
  end

  def run([effect, target]) when effect in @effects do
    Mix.Task.run("app.start")
    apply_effect(effect, target)
    Mix.shell().info("#{effect} >> #{target}")
  end

  def run(_) do
    Mix.shell().info("""
    Usage:
      mix mc.fx title <target> "Title" ["Subtitle"]
      mix mc.fx welcome|celebration|death|achievement|firework <target>
      mix mc.fx sound <target> <sound_name> [pitch]
      mix mc.fx particle <target> <particle_type>
    """)
  end

  defp apply_effect("welcome", target), do: Effects.welcome(target)
  defp apply_effect("celebration", target), do: Effects.celebration(target)
  defp apply_effect("death", target), do: Effects.death_effect(target)
  defp apply_effect("achievement", target), do: Effects.achievement_fanfare(target)
  defp apply_effect("firework", target), do: Effects.firework(target)

  defp parse_float(nil, default), do: default

  defp parse_float(str, default) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> default
    end
  end
end
