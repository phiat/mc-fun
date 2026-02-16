# MC Fun

Phoenix LiveView app that controls a Minecraft server via RCON and mineflayer bots with LLM-powered chat.

## Features

- **Dashboard** — LiveView UI with tabs for bot management, player status, RCON console, effects, display, and events
- **Mineflayer bots** — Node.js bots controlled via Erlang Ports (JSON over stdin/stdout)
- **LLM chat** — Groq-powered bot personalities with tool calling (dig, follow, craft, etc.)
- **RCON** — Full server control: commands, effects, teleporting, whitelisting
- **Bot behaviors** — Patrol, follow, guard modes via DynamicSupervisor
- **Effects** — Celebrations, fireworks, welcome effects, death events
- **Display** — Block text rendering in-world
- **Event system** — PubSub-based event dispatch with in-memory store

## Setup

```bash
cd mc_fun/

# Install dependencies
mix setup

# Configure environment (see .env.example or CLAUDE.md for details)
# Needs: RCON_HOST, RCON_PASSWORD, RCON_PORT, MC_HOST, MC_PORT, GROQ_API_KEY

# Start the server
mix phx.server
```

Dashboard at http://localhost:4000/dashboard

## In-game Bot Commands

- `!ask <question>` — Ask the LLM a question
- `!model <id>` — Switch Groq model
- `!models` — List available models
- `!personality <text>` — Change bot personality
- `!reset` — Clear conversation history
- `!tp` / `!tp <player>` — Teleport bot
- Whispers always get a response (no prefix needed)

## Development

```bash
mix precommit    # compile (warnings-as-errors), format, credo --strict, test
mix test          # run tests only
```

See `CLAUDE.md` for full architecture docs, supervision tree, and key patterns.
