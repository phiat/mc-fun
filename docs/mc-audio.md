# Minecraft Audio Reference

Practical reference for Minecraft Java Edition audio — sound events, note blocks, music discs, custom audio, and RCON integration.

## Sound System Overview

Minecraft's audio engine plays **sound events** — named identifiers mapped to one or more `.ogg` files. The game selects a random variant when multiple files are mapped to the same event.

**Distance attenuation**: Sounds have a base range of 16 blocks. Beyond that range, they are inaudible. The `volume` parameter in `/playsound` can extend effective range: volumes >1.0 increase the audible radius (radius = volume * 16 blocks) without changing perceived loudness at the source.

**Sound categories** control independent volume sliders in the client's audio settings:

| Category   | Controls                                      |
|------------|-----------------------------------------------|
| `master`   | Overall volume — scales all others             |
| `music`    | Background music                               |
| `record`   | Jukeboxes and music discs                      |
| `weather`  | Rain, thunder                                  |
| `block`    | Block placement, breaking, footsteps           |
| `hostile`  | Hostile mob sounds                             |
| `neutral`  | Passive/neutral mob sounds                     |
| `player`   | Player damage, eating, etc.                    |
| `ambient`  | Cave ambience, underwater sounds               |
| `voice`    | Narrator, text-to-speech (Bedrock/Education)   |

## The /playsound Command

```
/playsound <sound> <source> <targets> [pos] [volume] [pitch] [minVolume]
```

| Parameter    | Type          | Description                                                              |
|-------------|---------------|--------------------------------------------------------------------------|
| `sound`     | resource ID   | Namespaced sound event, e.g. `minecraft:block.note_block.harp`           |
| `source`    | category      | One of: `master`, `music`, `record`, `weather`, `block`, `hostile`, `neutral`, `player`, `ambient`, `voice` |
| `targets`   | selector      | Target players, e.g. `@a`, `@p`, `Steve`                                |
| `pos`       | x y z         | Position to play at. Use `~ ~ ~` for target's location                  |
| `volume`    | float         | 0.0+. Values >1.0 extend range without increasing loudness at source     |
| `pitch`     | float         | 0.5–2.0. Default 1.0. Each doubling = one octave up                      |
| `minVolume` | float         | 0.0–1.0. Minimum volume for players outside normal range                 |

### /stopsound

```
/stopsound <targets> [source] [sound]
```

Stops sounds currently playing. Omit `source`/`sound` to stop all sounds. Useful for cutting long ambient sounds or music.

### Sound Event Namespace Format

All sound events follow `namespace:category.source.variant`:

```
minecraft:block.note_block.harp
minecraft:entity.player.levelup
minecraft:ui.toast.challenge_complete
minecraft:entity.wither.ambient
minecraft:music_disc.pigstep
minecraft:ambient.cave
```

Common prefixes: `block.*`, `entity.*`, `item.*`, `music.*`, `music_disc.*`, `ambient.*`, `ui.*`, `weather.*`.

## Note Blocks

Right-clicking a note block cycles through 25 pitches (0–24). The instrument is determined by the block directly below the note block.

### Pitch Table

Note blocks span two octaves: F#3 (pitch 0) to F#5 (pitch 24).

| Pitch | Note | /playsound pitch value |
|-------|------|----------------------|
| 0     | F#3  | 0.5                  |
| 1     | G3   | 0.5297               |
| 2     | G#3  | 0.5612               |
| 3     | A3   | 0.5946               |
| 4     | A#3  | 0.6300               |
| 5     | B3   | 0.6674               |
| 6     | C4   | 0.7071               |
| 7     | C#4  | 0.7492               |
| 8     | D4   | 0.7937               |
| 9     | D#4  | 0.8409               |
| 10    | E4   | 0.8909               |
| 11    | F4   | 0.9439               |
| 12    | F#4  | 1.0                  |
| 13    | G4   | 1.0595               |
| 14    | G#4  | 1.1225               |
| 15    | A4   | 1.1892               |
| 16    | A#4  | 1.2599               |
| 17    | B4   | 1.3348               |
| 18    | C5   | 1.4142               |
| 19    | C#5  | 1.4983               |
| 20    | D5   | 1.5874               |
| 21    | D#5  | 1.6818               |
| 22    | E5   | 1.7818               |
| 23    | F5   | 1.8877               |
| 24    | F#5  | 2.0                  |

**Formula**: `pitch = 0.5 * 2^(n/12)` where n = pitch value (0–24). Equivalently, `pitch = 2^((n - 12) / 12)`.

### Instruments by Block Below

| Block Below                           | Instrument       | Sound Event Suffix     |
|---------------------------------------|------------------|------------------------|
| Any wood/log/plank (default)          | Harp/Piano       | `harp`                 |
| Sand, gravel, concrete powder         | Snare drum       | `snare`                |
| Glass, sea lantern, beacon            | Hi-hat/Clicks    | `hat`                  |
| Stone, blackstone, netherrack, obsidian, quartz, sandstone, ores, bricks, cobblestone, concrete, terracotta, purpur, prismarine, coral | Bass drum | `basedrum` |
| Gold block                            | Bells            | `bell`                 |
| Clay                                  | Flute            | `flute`                |
| Packed ice                            | Chimes           | `chime`                |
| Wool                                  | Guitar           | `guitar`               |
| Bone block                            | Xylophone        | `xylophone`            |
| Iron block                            | Iron xylophone   | `iron_xylophone`       |
| Soul sand                             | Cow bell         | `cow_bell`             |
| Pumpkin                               | Didgeridoo       | `didgeridoo`           |
| Emerald block                         | "Bit"            | `bit`                  |
| Hay bale                              | Banjo            | `banjo`                |
| Glowstone                             | Pling            | `pling`                |
| Any other / air                       | Harp/Piano       | `harp`                 |

### Mob Head Variants

Placing a mob head on top of a note block plays that mob's ambient sound instead:
- Zombie head, Skeleton skull, Wither skeleton skull, Creeper head, Piglin head, Dragon head.

## Music Discs

### Obtaining

Music discs drop when a skeleton's (or stray's) arrow kills a creeper. Some discs are found in structure loot chests (dungeons, woodland mansions, ancient cities, trail ruins). "Pigstep" and "otherside" are loot-only.

### Jukebox Mechanics

- Right-click a jukebox with a disc to play it.
- Right-click again or break the jukebox to eject the disc.
- Jukeboxes emit a redstone comparator signal (strength 1–15 depending on the disc).
- Sound plays in the `record` category.
- Audible range: ~65 blocks.
- In 1.20+, jukeboxes emit note particles while playing.

### Complete Disc List

| Disc             | Composer       | Comparator Signal |
|------------------|----------------|:-----------------:|
| 13               | C418           | 1                 |
| cat              | C418           | 2                 |
| blocks           | C418           | 3                 |
| chirp            | C418           | 4                 |
| far              | C418           | 5                 |
| mall             | C418           | 6                 |
| mellohi          | C418           | 7                 |
| stal             | C418           | 8                 |
| strad            | C418           | 9                 |
| ward             | C418           | 10                |
| 11               | C418           | 11                |
| wait             | C418           | 12                |
| Pigstep          | Lena Raine     | 13                |
| otherside        | Lena Raine     | 14                |
| 5                | Samuel Aberg   | 15                |
| Relic            | Aaron Cherof   | —                 |
| Creator          | Lena Raine     | —                 |
| Creator (Music Box) | Lena Raine | —                 |
| Precipice        | Aaron Cherof   | —                 |

C418 composed the original 12 discs. Lena Raine added Pigstep (1.16), otherside (1.18), and Creator/Creator (Music Box) (1.21). Samuel Aberg composed disc 5 (1.19, found in ancient cities). Aaron Cherof composed Relic (1.20, found in trail ruins) and Precipice (1.21).

### Playing Discs via RCON

There is no direct `/playsound` for full disc tracks (they are long-form audio, not sound events). To play a disc sound event:

```
/playsound minecraft:music_disc.pigstep record @a ~ ~ ~
```

This plays the full track. Use `/stopsound` to stop it:

```
/stopsound @a record minecraft:music_disc.pigstep
```

## Resource Packs & Custom Audio

### Audio Format

Minecraft requires **Ogg Vorbis** (`.ogg`) format. Mono files are spatialized (3D positioned); stereo files play at equal volume regardless of position.

### File Structure

```
assets/
  minecraft/                          # or custom namespace
    sounds.json                       # sound event definitions
    sounds/
      custom/
        my_sound.ogg
        my_music.ogg
```

### sounds.json Structure

```json
{
  "custom.my_sound": {
    "sounds": [
      {
        "name": "custom/my_sound",
        "volume": 1.0,
        "pitch": 1.0,
        "weight": 1,
        "stream": false
      }
    ]
  },
  "custom.my_music": {
    "sounds": [
      {
        "name": "custom/my_music",
        "stream": true
      }
    ]
  }
}
```

Key fields per sound entry:

| Field    | Default | Description                                                    |
|----------|---------|----------------------------------------------------------------|
| `name`   | —       | Path relative to `sounds/`, without `.ogg` extension            |
| `volume` | 1.0     | Volume multiplier                                               |
| `pitch`  | 1.0     | Pitch multiplier                                                |
| `weight` | 1       | Random selection weight when multiple sounds share an event      |
| `stream` | false   | Stream from disk instead of loading into memory. Use for long audio (music) |
| `type`   | "file"  | `"file"` (default) or `"event"` (redirect to another sound event) |

The top-level key is the sound event name. Set `"replace": true` at the event level to override vanilla sounds instead of adding variants.

### Using Custom Sounds

Once a resource pack with custom sounds is active:

```
/playsound minecraft:custom.my_sound master @a ~ ~ ~
```

For a custom namespace:

```
/playsound mynamespace:custom.my_sound master @a ~ ~ ~
```

## RCON Integration

All `/playsound` and `/stopsound` commands work identically over RCON. The server executes them server-side; the target client(s) receive the audio packets.

### Key Behaviors via RCON

- **Position `~ ~ ~`**: Resolves to the *server's* origin (0 0 0) when no execution context exists. Use `execute at <target> run playsound ...` or specify coordinates explicitly.
- **Volume >1.0**: Extends range. A volume of 4.0 is audible at 64 blocks.
- **Pitch 0.5–2.0**: Values outside this range are clamped.
- **Response**: Returns empty string on success, error message on failure (bad sound ID, no targets found).

### Pattern: Play at Target's Position

```
execute at @a run playsound minecraft:block.note_block.harp master @s ~ ~ ~ 1 1.0
```

This runs `/playsound` at each player's own position using `@s` relative to the `execute at` context.

### Pattern: Stop All Sounds

```
stopsound @a
```

### Pattern: Ambient Background

```
playsound minecraft:music_disc.cat record @a ~ ~ ~ 0.3
```

Low volume, `record` category so players can mute via Music/Jukebox slider.

## MC Fun Audio Integration

### McFun.Music (`apps/mc_fun/lib/mc_fun/music.ex`)

Plays melodies note-by-note via RCON using note block sound events.

**Architecture**: Converts note names (e.g. `C4`, `D#5`) to Minecraft pitch values using the formula `0.5 * 2^(semitones_from_F#3 / 12)`. Supports durations (whole, half, quarter, eighth, sixteenth) and rests.

**Instruments available** (mapped to `block.note_block.*`):
`harp`, `bass`, `basedrum`, `bell`, `chime`, `flute`, `guitar`, `iron_xylophone`, `xylophone`, `bit`, `banjo`, `pling`

**Song file format** (one note per line or space-separated):
```
# Comments start with #
C4:q D4:q E4:q F4:q
G4:h
R:q          # rest
E4:e E4:e    # eighth notes
```

**Usage**:
```elixir
McFun.Music.play("songs/twinkle.txt")
McFun.Music.play_notes([{"C4", :q}, {"D4", :q}], bpm: 140, instrument: "bell")
McFun.Music.play_inline("C4:q D4:q E4:h", instrument: "flute", target: "Steve")
```

**RCON command generated per note**:
```
playsound minecraft:block.note_block.harp master @a ~ ~ ~ 1 <pitch>
```

Note: Uses `~ ~ ~` for position, which means the sound originates at the executing context. Since RCON has no entity context, this resolves to world origin. Wrapping in `execute at <target> run ...` would fix spatialization but is not currently implemented.

### McFun.Effects (`apps/mc_fun/lib/mc_fun/effects.ex`)

Provides preset audio+visual combos via RCON.

**Sound-related functions**:

| Function              | Sound Used                                | Purpose            |
|-----------------------|-------------------------------------------|-------------------|
| `sound/3`             | Any sound event                           | Generic playback   |
| `celebration/1`       | `entity.player.levelup`                   | Level-up chime     |
| `death_effect/1`      | `entity.wither.ambient` (vol 0.5)         | Death atmosphere   |
| `achievement_fanfare/1` | `ui.toast.challenge_complete`           | Achievement sound  |
| `welcome/1`           | `block.note_block.harp` (pitch 1.5)       | Welcome jingle     |

All sounds are played in the `master` category.

### Potential Enhancements

- **Spatial audio**: Wrap `/playsound` in `execute at <target> run ...` so sounds originate at the player, not world origin.
- **Category awareness**: Use `record` for music playback (respects player's jukebox volume slider) instead of `master`.
- **Custom resource pack**: Ship an `.ogg` resource pack for custom bot sounds, alerts, or background music. Requires players to accept the pack (configurable in `server.properties` with `resource-pack=` and `resource-pack-sha1=`).
- **Chord support**: Play multiple notes simultaneously by removing the sleep between concurrent `/playsound` calls.
- **Disc playback**: Add jukebox-style commands to play full music disc tracks via `/playsound minecraft:music_disc.<name> record @a`.
- **Dynamic BPM**: Tempo changes mid-song via markers in the song file format.
