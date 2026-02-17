defmodule McFun.World.Effects do
  @moduledoc """
  Visual and audio effects library for Minecraft via RCON.

  Provides fireworks, particles, sounds, titles, and preset combos.

  ## Usage

      McFun.World.Effects.firework("Steve")
      McFun.World.Effects.particle("minecraft:heart", "Steve", count: 30)
      McFun.World.Effects.celebration("@a")
  """

  require Logger

  # --- Fireworks ---

  @doc """
  Summon a firework rocket at the target's position.

  Options:
  - `:colors` — list of integer RGB colors (default `[16711680]` red)
  - `:shape` — "small_ball", "large_ball", "star", "burst", "creeper" (default "burst")
  - `:flight` — flight duration 0-3 (default 1)
  """
  @spec firework(String.t(), keyword()) :: :ok | {:error, term()}
  def firework(target, opts \\ []) do
    colors = Keyword.get(opts, :colors, [16_711_680])
    shape = Keyword.get(opts, :shape, "burst")
    flight = Keyword.get(opts, :flight, 1)

    colors_nbt = Enum.join(colors, ",")

    cmd =
      ~s(execute at #{target} run summon minecraft:firework_rocket ~ ~1 ~ ) <>
        ~s({LifeTime:20,FireworksItem:{id:"minecraft:firework_rocket",count:1,) <>
        ~s(components:{"minecraft:fireworks":{explosions:[{shape:"#{shape}",) <>
        ~s(colors:[I;#{colors_nbt}]}],flight_duration:#{flight}\}}}})

    rcon(cmd)
  end

  # --- Particles ---

  @doc """
  Spawn particles at the target's position.

  Common types: "minecraft:heart", "minecraft:flame", "minecraft:cloud",
  "minecraft:totem_of_undying", "minecraft:smoke", "minecraft:soul"

  Options:
  - `:count` — number of particles (default 20)
  - `:spread` — spread radius (default 1.0)
  - `:speed` — particle speed (default 0)
  """
  @spec particle(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def particle(type, target, opts \\ []) do
    count = Keyword.get(opts, :count, 20)
    spread = Keyword.get(opts, :spread, 1.0)
    speed = Keyword.get(opts, :speed, 0)

    cmd =
      "execute at #{target} run particle #{type} ~ ~1 ~ #{spread} #{spread} #{spread} #{speed} #{count}"

    rcon(cmd)
  end

  # --- Sounds ---

  @doc """
  Play a sound at the target's position.

  Options:
  - `:volume` — 0.0-1.0 (default 1)
  - `:pitch` — 0.5-2.0 (default 1)
  """
  @spec sound(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def sound(sound_name, target, opts \\ []) do
    volume = Keyword.get(opts, :volume, 1)
    pitch = Keyword.get(opts, :pitch, 1)

    cmd = "playsound minecraft:#{sound_name} master #{target} ~ ~ ~ #{volume} #{pitch}"
    rcon(cmd)
  end

  # --- Titles ---

  @doc """
  Display a title on the target's screen.

  Options:
  - `:subtitle` — subtitle text
  - `:fade_in` — ticks (default 10)
  - `:stay` — ticks (default 70)
  - `:fade_out` — ticks (default 20)
  """
  @spec title(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def title(target, text, opts \\ []) do
    subtitle = Keyword.get(opts, :subtitle)
    fade_in = Keyword.get(opts, :fade_in, 10)
    stay = Keyword.get(opts, :stay, 70)
    fade_out = Keyword.get(opts, :fade_out, 20)

    rcon("title #{target} times #{fade_in} #{stay} #{fade_out}")
    Process.sleep(50)
    rcon(~s(title #{target} title {"text":"#{text}"}))

    if subtitle do
      Process.sleep(50)
      rcon(~s(title #{target} subtitle {"text":"#{subtitle}"}))
    end

    :ok
  end

  # --- Presets ---

  @doc "Celebration: firework + totem particles + level-up sound."
  @spec celebration(String.t()) :: :ok
  def celebration(target) do
    firework(target, colors: [16_776_960, 16_777_215], shape: "burst")
    Process.sleep(200)
    particle("minecraft:totem_of_undying", target, count: 50)
    Process.sleep(50)
    sound("entity.player.levelup", target)
    :ok
  end

  @doc "Death effect: smoke particles + wither sound."
  @spec death_effect(String.t()) :: :ok
  def death_effect(target) do
    particle("minecraft:smoke", target, count: 40, spread: 0.5)
    Process.sleep(50)
    sound("entity.wither.ambient", target, volume: 0.5)
    :ok
  end

  @doc "Achievement fanfare: firework + challenge-complete sound."
  @spec achievement_fanfare(String.t()) :: :ok
  def achievement_fanfare(target) do
    firework(target, colors: [65_280, 16_776_960], shape: "star")
    Process.sleep(200)
    sound("ui.toast.challenge_complete", target)
    :ok
  end

  @doc "Welcome: title + harp sound."
  @spec welcome(String.t()) :: :ok
  def welcome(target) do
    title(target, "Welcome!", subtitle: "Enjoy your stay")
    Process.sleep(100)
    sound("block.note_block.harp", target, pitch: 1.5)
    :ok
  end

  # --- Helpers ---

  defp rcon(cmd) do
    case McFun.Rcon.command(cmd) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("Effects RCON error: #{inspect(reason)}")
        err
    end
  end
end
