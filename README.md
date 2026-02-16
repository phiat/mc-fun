# MC Fun

Phoenix LiveView control panel for a Minecraft server. Manage bots, RCON commands, effects, block text displays, and events from a browser dashboard.

## Features

- **Bot Management** — Spawn and control mineflayer bots via Erlang Ports
- **LLM Chat** — Bots respond to players using Groq LLM models (configurable per-bot)
- **Personality Presets** — 22 themed bot personalities across 6 categories
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
Phoenix LiveView Dashboard
    │
    ├── McFun.Rcon ──────── Minecraft Server (RCON)
    ├── McFun.Bot ──────── bridge.js (mineflayer, Erlang Port)
    ├── McFun.ChatBot ──── Groq LLM API
    ├── McFun.BotBehaviors ── Patrol/Follow/Guard
    ├── McFun.Effects ──── RCON particle/sound commands
    └── McFun.Display ──── Block text rendering
```

## In-Game Commands

| Command | Description |
|---------|-------------|
| `!ask <question>` | Ask the bot's LLM a question |
| `!model <id>` | Switch the bot's LLM model |
| `!models` | List available models |
| `!personality <text>` | Change the bot's personality |
| `!reset` | Clear conversation history |
| `!tp [player]` | Teleport bot to a player |
| `/msg BotName <text>` | Whisper to bot (always gets a response) |

## Tech Stack

- Elixir / Phoenix 1.8 / LiveView 1.1
- Node.js (mineflayer bridge)
- Groq API (LLM)
- Tailwind CSS
