# MC Fun

Phoenix LiveView control panel for a Minecraft server. Manage bots, RCON commands, effects, block text displays, and events from a browser dashboard.

## Features

- **Bot Management** — Spawn and control mineflayer bots via Erlang Ports
- **LLM Chat** — Bots respond to players using Groq LLM models (configurable per-bot)
- **LLM-to-Action** — Bots perform physical actions (dig, follow, attack, etc.) when their LLM response implies it
- **A* Pathfinding** — Bots navigate using mineflayer-pathfinder for goto/follow/patrol
- **Personality Presets** — 22 themed bot personalities across 6 categories
- **Bot Config Modal** — Per-bot model, personality, behavior, and action controls
- **Bot Status** — Live HP/food bars, position, dimension on each bot card
- **RCON Console** — Execute server commands from the dashboard
- **Effects** — Celebration, welcome, death, achievement, firework effects
- **Block Display** — Render text as blocks in the Minecraft world
- **Event Stream** — Real-time event log (joins, leaves, chat, deaths, advancements)
- **Behaviors** — Patrol, follow, and guard behaviors for bots

## Setup

```bash
cd mc_fun/
cp ../.env.example ../.env  # configure RCON_HOST, GROQ_API_KEY, etc.
mix deps.get
cd priv/mineflayer && npm install && cd ../..
mix phx.server              # http://localhost:4000/dashboard
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `RCON_HOST` | Minecraft server RCON host |
| `RCON_PORT` | RCON port (default: 25575) |
| `RCON_PASSWORD` | RCON password |
| `MC_HOST` | Minecraft server host (for bots) |
| `MC_PORT` | Minecraft server port (default: 25565) |
| `GROQ_API_KEY` | Groq API key for LLM chat |

## Architecture

```
Phoenix LiveView Dashboard (/dashboard)
    │
    ├── McFun.Bot ──────────── bridge.js (mineflayer + pathfinder, Erlang Port)
    │   ├── dig, place, equip, craft, drop, goto, follow, jump, sneak, attack
    │   └── status: position, health, food, dimension (polled every 5s)
    │
    ├── McFun.ChatBot ─────── Groq LLM API
    │   ├── !ask, !model, !models, !personality, !reset, !tp
    │   └── whispers always get a response
    │
    ├── McFun.ActionParser ── Regex-based LLM response → bot action translator
    │   └── "I'll dig that" → Bot.send_command("dig_looking_at")
    │
    ├── McFun.BotBehaviors ── Persistent behaviors (1 per bot, 1s tick)
    │   └── patrol (waypoints loop), follow (player), guard (position + radius)
    │
    ├── McFun.Presets ─────── 22 bot personalities across 6 categories
    │
    ├── McFun.Rcon ────────── Minecraft Server (RCON)
    ├── McFun.Effects ─────── RCON particle/sound commands
    └── McFun.Display ─────── Block text rendering
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

## Dashboard Controls

### Bot Cards
- HP bar, food bar, position (X/Y/Z), dimension
- Model switcher, behavior status
- Teleport buttons per online player
- CONFIGURE button → full config modal

### Config Modal (per bot)
- **LLM tab** — model, personality editor, preset quick-apply, conversation viewer
- **BEHAVIOR tab** — patrol/follow/guard with stop button
- **ACTIONS tab** — chat, goto, teleport, jump/sneak/attack

### Other Tabs
- **RCON** — command terminal
- **FX** — particle/sound effects
- **DISPLAY** — block text rendering
- **EVENTS** — real-time event stream

## Tech Stack

- Elixir / Phoenix 1.8 / LiveView 1.1
- Node.js (mineflayer + mineflayer-pathfinder bridge)
- Groq API (LLM)
- Tailwind CSS
