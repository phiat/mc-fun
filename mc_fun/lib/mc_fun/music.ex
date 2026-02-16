defmodule McFun.Music do
  @moduledoc """
  Minecraft music player using RCON /playsound commands.

  Song format (one note per line):
    C4:q    — quarter note C4
    D4:h    — half note D4
    E4:w    — whole note
    R:q     — quarter rest
    C4:e    — eighth note

  Instruments: harp, bass, basedrum, bell, chime, flute, guitar, iron_xylophone, xylophone, bit, banjo, pling, didgeridoo, cow_bell

  Usage:
    McFun.Music.play("songs/twinkle.txt")
    McFun.Music.play_notes([{"C4", :q}, {"D4", :q}, {"E4", :h}])
  """
  require Logger

  # Minecraft pitch values: F#3=0.5, G3=0.53, ... C5=2.0
  # Each semitone is 2^(1/12) apart. Base: F#3 = 0.5
  # F#3 in MIDI
  @base_note_num 42
  @base_pitch 0.5

  # Note name to MIDI number (octave 4: C4=60)
  @note_names %{
    "C" => 0,
    "C#" => 1,
    "Db" => 1,
    "D" => 2,
    "D#" => 3,
    "Eb" => 3,
    "E" => 4,
    "F" => 5,
    "F#" => 6,
    "Gb" => 6,
    "G" => 7,
    "G#" => 8,
    "Ab" => 8,
    "A" => 9,
    "A#" => 10,
    "Bb" => 10,
    "B" => 11
  }

  # Duration in beats (at 120 BPM, quarter = 500ms)
  @durations %{
    # whole
    "w" => 4.0,
    # half
    "h" => 2.0,
    # quarter
    "q" => 1.0,
    # eighth
    "e" => 0.5,
    # sixteenth
    "s" => 0.25
  }

  # Instrument mapping
  @instruments %{
    "harp" => "block.note_block.harp",
    "bass" => "block.note_block.bass",
    "basedrum" => "block.note_block.basedrum",
    "bell" => "block.note_block.bell",
    "chime" => "block.note_block.chime",
    "flute" => "block.note_block.flute",
    "guitar" => "block.note_block.guitar",
    "iron_xylophone" => "block.note_block.iron_xylophone",
    "xylophone" => "block.note_block.xylophone",
    "bit" => "block.note_block.bit",
    "banjo" => "block.note_block.banjo",
    "pling" => "block.note_block.pling"
  }

  @doc "Play a song file. Options: :bpm (default 120), :instrument (default harp), :target (default @a)"
  def play(file_path, opts \\ []) do
    path =
      if String.starts_with?(file_path, "/") do
        file_path
      else
        Path.join(:code.priv_dir(:mc_fun), file_path)
      end

    case File.read(path) do
      {:ok, content} ->
        notes = parse_song(content)
        play_notes(notes, opts)

      {:error, reason} ->
        {:error, {:file_error, reason, path}}
    end
  end

  @doc "Play a list of {note, duration} tuples."
  def play_notes(notes, opts \\ []) do
    bpm = Keyword.get(opts, :bpm, 120)
    instrument = Keyword.get(opts, :instrument, "harp")
    target = Keyword.get(opts, :target, "@a")

    beat_ms = round(60_000 / bpm)
    sound = Map.get(@instruments, instrument, "block.note_block.harp")

    Logger.info("Playing #{length(notes)} notes at #{bpm} BPM with #{instrument}")

    Enum.each(notes, fn {note, duration_key} ->
      duration = Map.get(@durations, to_string(duration_key), 1.0)
      sleep_ms = round(duration * beat_ms)

      case note do
        "R" ->
          Process.sleep(sleep_ms)

        note_str ->
          case note_to_pitch(note_str) do
            {:ok, pitch} ->
              cmd = "playsound minecraft:#{sound} master #{target} ~ ~ ~ 1 #{pitch}"
              McFun.Rcon.command(cmd)
              Process.sleep(sleep_ms)

            {:error, _} ->
              Logger.warning("Invalid note: #{note_str}")
              Process.sleep(sleep_ms)
          end
      end
    end)

    :ok
  end

  @doc "Play a quick sequence (no file needed). Example: play_inline(\"C4:q D4:q E4:q F4:q G4:h\")"
  def play_inline(notes_str, opts \\ []) do
    notes = parse_song(notes_str)
    play_notes(notes, opts)
  end

  # Parsing

  defp parse_song(content) do
    content
    |> String.split(~r/[\n\s]+/, trim: true)
    |> Enum.filter(&(&1 != ""))
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&parse_note/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_note(str) do
    case String.split(str, ":") do
      [note, duration] -> {note, duration}
      [note] -> {note, "q"}
      _ -> nil
    end
  end

  # Note to Minecraft pitch conversion

  defp note_to_pitch(note_str) do
    case parse_note_name(note_str) do
      {:ok, midi_num} ->
        semitones = midi_num - @base_note_num
        # Minecraft pitch range: 0.5 (F#3) to 2.0 (F#5) = 24 semitones
        if semitones >= 0 and semitones <= 24 do
          pitch = @base_pitch * :math.pow(2, semitones / 12)
          {:ok, Float.round(pitch, 4)}
        else
          {:error, :out_of_range}
        end

      error ->
        error
    end
  end

  defp parse_note_name(str) do
    case Regex.run(~r/^([A-Ga-g][#b]?)(\d)$/, str) do
      [_, name, octave_str] ->
        name = String.upcase(name)
        octave = String.to_integer(octave_str)

        case Map.get(@note_names, name) do
          nil -> {:error, :invalid_note}
          semitone -> {:ok, (octave + 1) * 12 + semitone}
        end

      _ ->
        {:error, :invalid_format}
    end
  end
end
