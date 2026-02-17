# MC Fun

Phoenix LiveView control panel for a Minecraft server. Manage bots, execute RCON commands, fire effects, render block text, and watch events — all from a browser dashboard or the command line.

## Features

**Bots**
- Spawn and control [mineflayer](https://github.com/PrismarineJS/mineflayer) bots via Erlang Ports
- LLM chat via Groq — bots respond to players, perform actions based on LLM output
- A* pathfinding (mineflayer-pathfinder) for goto, follow, patrol
- 22 personality presets across 6 categories
- Behaviors: patrol (waypoint loop), follow (player), guard (position + radius)
- Per-bot config modal: model, personality, behaviors, actions

**Dashboard**
- Live bot cards with HP/food bars, position, dimension
- Player cards with stats and `[USE]` coord buttons
- RCON terminal with command history, Tab-repeat, and quick command palette
- Entity picker dropdowns in FX and Display panels
- Effects panel with presets + custom title/subtitle messages
- Block text display with entity-based coordinate fill
- Real-time event stream (joins, leaves, chat, deaths, advancements)

**CLI**
- Full suite of `mix mc.*` tasks mirroring dashboard functionality
- Effects, titles, sounds, and particles via `mix mc.fx`
- Live event watcher and system health check

**Engine**
- SNBT parser — recursive descent parser for Minecraft's NBT text format
- In-memory state (GenServers, ETS, EventStore) — no database

## Setup

### 1. Infrastructure (Incus containers)

Requires [Incus](https://linuxcontainers.org/incus/) installed on the host.

```bash
bin/mc up                   # launch Minecraft + Postgres containers
bin/mc status               # show IPs and connection strings
bin/mc doctor               # verify everything is healthy
```

### 2. Elixir app (runs on host)

```bash
cp .env.example .env        # fill in IPs from `bin/mc status`
mix deps.get
cd apps/mc_fun/priv/mineflayer && npm install && cd ../../../..
mix phx.server              # http://localhost:4000/dashboard
```

### Infrastructure CLI (`bin/mc`)

```bash
bin/mc up [mc|pg|all]       # start containers (default: all)
bin/mc down                 # stop all containers
bin/mc status               # show containers, IPs, connection strings
bin/mc connect mc            # shell into Minecraft container
bin/mc connect pg            # psql into Postgres
bin/mc logs mc 100           # last 100 lines of MC server logs
bin/mc doctor               # health check
```

### Ports

| Service    | Port  | Protocol |
|------------|-------|----------|
| Minecraft  | 25565 | TCP      |
| RCON       | 25575 | TCP      |
| Postgres   | 5432  | TCP      |
| Phoenix    | 4000  | HTTP     |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `RCON_HOST` | Minecraft container IP (from `bin/mc status`) |
| `RCON_PORT` | RCON port (default: 25575) |
| `RCON_PASSWORD` | RCON password (default: mc-fun-rcon) |
| `MC_HOST` | Minecraft container IP (same as RCON_HOST) |
| `MC_PORT` | Minecraft server port (default: 25565) |
| `GROQ_API_KEY` | Groq API key for LLM chat |
| `DATABASE_URL` | Postgres connection string (from `bin/mc status`) |

## Architecture

```
  Host (WSL2)                          Incus Containers
 ┌──────────────────────┐    ┌──────────────────────────────┐
 │  Elixir App          │    │  mc-fun-mc (Ubuntu Noble)    │
 │  Phoenix :4000       │───>│  Paper 1.21.4 + Java 21     │
 │    McFun.Rcon (:25575)    │  Game :25565  RCON :25575    │
 │    McFun.Bot  (:25565)    │  4GB RAM / 4 CPU             │
 │                      │    └──────────────────────────────┘
 │                      │    ┌──────────────────────────────┐
 │                      │───>│  mc-fun-pg (Ubuntu Noble)    │
 │                      │    │  Postgres 18 + TimescaleDB   │
 └──────────────────────┘    │  Port :5432                  │
                             │  1GB RAM / 2 CPU             │
                             └──────────────────────────────┘

Phoenix LiveView Dashboard (/dashboard)
    |
    |-- DashboardLive -------- Parent LiveView (tab routing, PubSub, shared state)
    |   |-- UnitsPanelLive     Bot deploy, cards, spawn/stop
    |   |-- RconConsoleLive    RCON terminal, history, quick commands
    |   |-- EventStreamLive    Real-time event log
    |   |-- EffectsPanelLive   Effects, titles, entity picker
    |   |-- DisplayPanelLive   Block text rendering
    |   +-- BotConfigModalLive Bot config modal (model, personality, behaviors)
    |
    |-- McFun.Bot ------------ bridge.js (mineflayer + pathfinder, Erlang Port)
    |   |-- dig, place, equip, craft, drop, goto, follow, jump, sneak, attack
    |   +-- status: position, health, food, dimension (polled every 5s)
    |
    |-- McFun.ChatBot -------- Groq LLM API
    |   |-- !ask, !model, !models, !personality, !reset, !tp
    |   +-- whispers always get a response
    |
    |-- McFun.ActionParser --- LLM response -> bot action (regex + tool calling)
    |-- McFun.BotBehaviors --- patrol / follow / guard (1s tick GenServers)
    |-- McFun.Presets -------- 22 bot personalities across 6 categories
    |-- McFun.SNBT ----------- NBT text -> Elixir maps/lists (recursive descent)
    |-- McFun.Rcon ----------- Minecraft Server (RCON)
    |-- McFun.World.Effects --- title, firework, particle, sound effects
    +-- McFun.World.Display --- Block text rendering
```

## In-Game Commands

| Command | Description |
|---------|-------------|
| `!ask <question>` | Ask the bot's LLM — bot performs actions it describes |
| `!model <id>` | Switch the bot's LLM model |
| `!models` | List available models |
| `!personality <text>` | Change the bot's personality |
| `!reset` | Clear conversation history |
| `!tp [player]` | Teleport bot to a player |
| `/msg BotName <text>` | Whisper to bot (always gets a response) |

## Dashboard Tabs

| Tab | Description |
|-----|-------------|
| **UNITS** | Bot cards (HP, food, position, model, behavior), deploy panel, config modal |
| **PLAYERS** | Online player cards with stats and `[USE]` coord button |
| **RCON** | Command terminal, history (arrow keys), Tab-repeat, quick command palette |
| **FX** | Entity picker, effect buttons, custom title/subtitle message form |
| **DISPLAY** | Block text rendering with entity-based coordinate fill |
| **EVENTS** | Real-time event stream |

## CLI Tools

```bash
# Server interaction
mix mc.cmd "say hello"                     # arbitrary RCON command
mix mc.players                             # list online players
mix mc.say Hello world!                    # broadcast chat message
mix mc.give Player diamond 64              # give item to player
mix mc.tp Player 0 64 0                   # teleport player
mix mc.weather clear                       # set weather
mix mc.time day                            # set time of day
mix mc.gamemode creative @a                # set gamemode
mix mc.effect @a speed 30 2                # give effect (duration, amplifier)
mix mc.heal @a                             # full heal + feed

# Effects & titles
mix mc.fx title @a "Hello" "subtitle"      # title screen message
mix mc.fx welcome @a                       # welcome effect (title + firework)
mix mc.fx celebration @a                   # celebration effect
mix mc.fx firework @a                      # firework
mix mc.fx sound @a block.note_block.harp   # play sound
mix mc.fx particle @a flame                # particle effect

# Observability
mix mc.status                              # system health check
mix mc.events                              # live event watcher (Ctrl+C to stop)
```

## Testing

```bash
mix test                                # unit tests (excludes smoke tests)
mix test apps/mc_fun/test --only smoke  # smoke tests (require live RCON)
mix precommit                           # compile + format + credo + test
```

## Tech Stack

- Elixir / Phoenix 1.8 / LiveView 1.1
- Node.js (mineflayer + mineflayer-pathfinder bridge)
- Groq API (LLM)
- Tailwind CSS
- Incus containers (Paper MC server, Postgres + TimescaleDB)
- No database yet — all state in-memory (Postgres provisioned for future event store)
