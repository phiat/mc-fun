# MC Fun — Elixir/Phoenix Minecraft Control Panel

## What This Is

Phoenix LiveView app that controls a Minecraft server via RCON and mineflayer bots.
The MC server runs remotely on **miniwini-1** (Incus/LXC container named `minecraft`).

## Running

```bash
cd mc_fun/
mix phx.server        # starts on http://localhost:4000
mix precommit         # compile --warnings-as-errors, format, credo --strict, test
```

Dashboard at `/dashboard`. Home page at `/`.

## Project Layout

```
mc_fun/
├── lib/mc_fun/                  # Core domain
│   ├── application.ex           # Supervision tree
│   ├── rcon.ex                  # RCON GenServer (crashes on auth fail — intentional)
│   ├── bot.ex                   # Mineflayer bot via Erlang Port + bridge.js (JSON over stdin/stdout)
│   ├── chat_bot.ex              # LLM chat — !ask/!model/!models/!personality/!reset/!tp
│   ├── action_parser.ex          # Regex-based LLM response → bot action translator
│   ├── bot_behaviors.ex         # Patrol/follow/guard behaviors (1s tick GenServers)
│   ├── bot_supervisor.ex        # DynamicSupervisor wrapper for bots
│   ├── presets.ex               # 22 bot personality presets across 6 categories
│   ├── log_watcher.ex           # RCON-polling log watcher (no local log file)
│   ├── events.ex                # PubSub event system
│   ├── events/handlers.ex       # Default event handler registration
│   ├── events/callback_handler.ex
│   ├── event_store.ex           # In-memory event store (recent events)
│   ├── effects.ex               # MC effects (celebration, welcome, death, firework, etc.)
│   ├── display.ex               # Block text rendering in-world
│   ├── display/block_font.ex    # Font definitions for block text
│   ├── music.ex                 # Music/sound via RCON
│   ├── redstone.ex              # Redstone circuit helpers
│   ├── redstone/executor.ex
│   ├── redstone/circuit_registry.ex
│   └── llm/
│       ├── groq.ex              # Groq API client (Req-based)
│       └── model_cache.ex       # ETS + disk cache of available Groq models
├── lib/mc_fun_web/
│   ├── router.ex                # / (home), /dashboard (LiveView), /api/webhooks/:action
│   ├── live/dashboard_live.ex   # Main UI — tabs: UNITS, PLAYERS, RCON, FX, DISPLAY, EVENTS
│   ├── controllers/
│   │   ├── page_controller.ex
│   │   ├── webhook_controller.ex
│   │   └── error_*.ex
│   └── components/
│       ├── core_components.ex
│       └── layouts.ex
└── priv/mineflayer/bridge.js    # Node.js mineflayer bridge (Erlang Port protocol)
```

## Supervision Tree (application.ex)

```
McFun.Supervisor (one_for_one)
├── McFunWeb.Telemetry
├── DNSCluster
├── Phoenix.PubSub (name: McFun.PubSub)
├── McFun.Rcon                      # RCON GenServer
├── McFun.Redstone.CircuitRegistry
├── McFun.LLM.ModelCache            # ETS + disk cache
├── McFun.EventStore
├── McFun.LogWatcher                # Polls RCON for player list
├── Registry (McFun.BotRegistry)    # Unique keys: bot_name, {:chat_bot, name}, {:behavior, name}
├── DynamicSupervisor (McFun.BotSupervisor)  # Bots, ChatBots, BotBehaviors
└── McFunWeb.Endpoint
```

After start: `McFun.Events.Handlers.register_all()` registers default event handlers.

## Key Patterns

- **Bot registry keys**: `"BotName"` (Bot), `{:chat_bot, "BotName"}` (ChatBot), `{:behavior, "BotName"}` (BotBehaviors)
- **PubSub topics**: `"bot:#{name}"` for bot events, `McFun.Events` for game events
- **Async in LiveView**: RCON commands and LLM calls use `Task.start` to avoid blocking the LiveView process. Results sent back via `send(lv, {:rcon_result, ...})`.
- **Bot ↔ bridge.js protocol**: Newline-delimited JSON over stdin/stdout. Bot sends commands as JSON, bridge.js sends events back.
- **ChatBot commands**: `!ask` (LLM query, rate-limited 2s), `!model`/`!models`, `!personality`, `!reset`, `!tp`. Whispers always trigger LLM response.
- **BotBehaviors**: One behavior per bot. Starting a new one stops the old. Tick-based (1s interval).
- **LLM tool calling**: ChatBot uses Groq function/tool calling for capable models (llama, qwen, openai/, meta-llama/, moonshotai/). Falls back to regex ActionParser for non-tool models (compound). `supports_tools?/1` checks prefixes.
- **ActionParser**: Regex fallback for models without tool support. Parses trigger phrases → `{action, params}` tuples → executed via Bot API.
- **Bot survey**: `Bot.survey/1` — synchronous call to bridge.js that returns nearby blocks, inventory, entities, position, health. Used by ChatBot before each LLM call for environment context.
- **Thinking strip**: `ChatBot.strip_thinking/1` removes chain-of-thought from reasoning models. Expects `REPLY:` marker; falls back to quoted-text extraction for CoT patterns.
- **Paginated chat**: `ChatBot.send_paginated/2` chunks responses at word boundaries (180 chars/line, max 4 lines, 300ms delay between).
- **Bot status polling**: Bot.ex polls bridge for position every 5s, tracks health/food/dimension from events. `terminate/2` closes port on shutdown.
- **Port safety**: Bot.ex checks `Port.info` before sending commands; returns `{:error, :port_dead}` if port is gone.
- **Presets**: `McFun.Presets.all/0`, `by_category/0`, `get/1`. 22 presets in 6 categories.
- **Bot actions in bridge.js**: dig, dig_looking_at, dig_area, find_and_dig, survey, place, equip, craft, drop, goto, follow, jump, sneak, attack, move, look, chat, whisper, inventory, position, players, quit.
- **Pathfinder**: mineflayer-pathfinder loaded on spawn, falls back to simple movement if init fails.
- **LogWatcher**: First poll silently populates player set (no spurious join events on restart).

## Environment

- `.env` in project root (`mc-fun/.env`) — real secrets (GROQ_API_KEY, RCON_PASSWORD, etc.)
- `.env` in `mc_fun/.env` — local overrides (RCON_HOST, MC_HOST point to miniwini-1)
- `runtime.exs` loads: `.env` → `../.env` → system env (via Dotenvy)
- NEVER delete .env files without reading them first
- Groq API key starts with `gsk_`

## Remote Server

```bash
ssh miniwini-1
incus exec minecraft -- <cmd>           # run command in MC container
# Server path inside container: /opt/minecraft/server/
# RCON: port 25575, password mcfun2026
# MC: port 25565
# Whitelisted: DonaldMahanahan, kurgenjlopp, McFunBot
```

## Dependencies (notable)

- Phoenix 1.8, LiveView 1.1, Bandit (HTTP server)
- Req (HTTP client for Groq API)
- Dotenvy (.env loading)
- Jason (JSON)
- No database — all state is in-memory (GenServers, ETS, EventStore)

## Gotchas

- The `mc-fun/mc_fun/` nesting is confusing — Phoenix app is in the inner `mc_fun/`
- `docker-compose.yml` in repo root is for LOCAL dev only, not the primary server
- RCON GenServer crashes the app if auth fails — this is intentional (fail fast)
- `BotSupervisor.list_bots/0` filters registry to binary-only keys to exclude tuples like `{:chat_bot, name}`
- Default LLM model: `openai/gpt-oss-20b` (via Groq)
- `mix precommit` runs compile (warnings-as-errors), deps.unlock --unused, format, credo --strict, test
