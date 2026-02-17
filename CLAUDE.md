# MC Fun — Elixir/Phoenix Minecraft Control Panel

## What This Is

Phoenix LiveView app that controls a Minecraft server via RCON and mineflayer bots.
The MC server runs remotely on a dedicated host (Incus/LXC container named `minecraft`).

## Running

```bash
mix phx.server        # starts on http://localhost:4000 (from repo root)
mix precommit         # compile --warnings-as-errors, format, credo --strict, test
```

Dashboard at `/dashboard`. Home page at `/`.

## CLI Tools

```bash
# Server interaction
mix mc.cmd "say hello"                  # arbitrary RCON command
mix mc.players                          # list online players
mix mc.say Hello world!                 # broadcast chat message
mix mc.give Player diamond 64           # give item
mix mc.tp Player 0 64 0                # teleport
mix mc.weather clear                    # set weather
mix mc.time day                         # set time
mix mc.gamemode creative @a             # set gamemode
mix mc.effect @a speed 30 2             # give effect (duration, amplifier)
mix mc.heal @a                          # full heal + feed

# Effects & titles
mix mc.fx title @a "Hello" "subtitle"   # title screen message
mix mc.fx welcome @a                    # welcome effect (title + firework)
mix mc.fx celebration @a                # celebration effect
mix mc.fx firework @a                   # firework
mix mc.fx sound @a block.note_block.harp # play sound
mix mc.fx particle @a flame             # particle effect

# Observability
mix mc.status                           # system health check (RCON, players, GenServers)
mix mc.events                           # live PubSub event watcher (Ctrl+C to stop)
```

## Testing

```bash
mix test                                # unit tests (smoke tests excluded by default)
mix test apps/mc_fun/test --only smoke  # smoke tests (require live RCON connection)
```

Smoke tests verify RCON connectivity, LogWatcher, EventStore, PubSub, and player data parsing.

## Project Layout (Umbrella)

```
mc-fun/                              # repo root = umbrella root
├── mix.exs                          # umbrella mix.exs
├── config/                          # shared config
├── apps/
│   ├── mc_fun/                      # engine app — RCON, LLM, events, world, infra
│   │   ├── lib/mc_fun/
│   │   │   ├── application.ex       # engine supervisor (PubSub, Rcon, LLM, events)
│   │   │   ├── rcon.ex              # RCON GenServer (crashes on auth fail — intentional)
│   │   │   ├── chat_log.ex          # Persistent chat log (JSONL + ring buffer + PubSub)
│   │   │   ├── log_watcher.ex       # RCON-polling log watcher (no local log file)
│   │   │   ├── events.ex            # PubSub event system
│   │   │   ├── events/handlers.ex   # Default event handler registration
│   │   │   ├── event_store.ex       # In-memory event store
│   │   │   ├── cost_tracker.ex      # LLM cost tracking
│   │   │   ├── snbt.ex             # SNBT parser public API
│   │   │   ├── snbt/parser.ex      # Recursive descent SNBT parser
│   │   │   ├── llm/                 # Groq API client + model cache
│   │   │   └── world/               # RCON-based world manipulation
│   │   │       ├── effects.ex       # MC effects (celebration, welcome, death, firework)
│   │   │       ├── display.ex       # Block text rendering in-world
│   │   │       ├── display/block_font.ex # 5x7 block-font bitmaps
│   │   │       ├── music.ex         # Music/sound via RCON
│   │   │       ├── redstone.ex      # Redstone circuit helpers
│   │   │       └── redstone/        # Circuit registry + executor
│   │   └── priv/
│   │
│   ├── bot_farmer/                  # bot fleet manager — bots, chatbot, behaviors, persistence
│   │   ├── lib/
│   │   │   ├── bot_farmer.ex        # Public facade API (BotFarmer.spawn_bot, etc.)
│   │   │   ├── bot_farmer/
│   │   │   │   ├── application.ex   # Supervisor: BotChat, BotStore, Registry, DynamicSupervisor
│   │   │   │   └── bot_store.ex     # Fleet persistence (bot_fleet.json) + auto-deploy
│   │   │   └── mc_fun/              # Moved modules (keep McFun.* names)
│   │   │       ├── bot.ex           # Mineflayer bot via Erlang Port + bridge.js
│   │   │       ├── chat_bot.ex      # LLM chat — !ask/!model/!models/!personality/!reset/!tp
│   │   │       ├── bot_chat.ex      # Bot-to-bot chat coordinator
│   │   │       ├── action_parser.ex # Regex-based LLM response → bot action translator
│   │   │       ├── bot_behaviors.ex # Patrol/follow/guard/mine behaviors
│   │   │       ├── bot_supervisor.ex # DynamicSupervisor wrapper for bots
│   │   │       └── presets.ex       # 22 bot personality presets across 6 categories
│   │   └── priv/mineflayer/bridge.js # Node.js mineflayer bridge
│   │
│   └── mc_fun_web/                  # web app — Phoenix, LiveView, dashboard
│       ├── lib/mc_fun_web/
│       │   ├── application.ex       # web supervisor (Telemetry, DNSCluster, Endpoint)
│       │   ├── endpoint.ex
│       │   ├── router.ex            # / (home), /dashboard (LiveView), /api/webhooks/:action
│       │   ├── live/
│       │   │   ├── dashboard_live.ex       # Parent LiveView — tab routing, PubSub, shared state
│       │   │   ├── dashboard_live.html.heex # Template — tab nav, delegates to LiveComponents
│       │   │   ├── units_panel_live.ex     # UNITS tab — deploy config, bot cards, spawn/stop
│       │   │   ├── rcon_console_live.ex    # RCON tab — terminal, history, quick commands
│       │   │   ├── event_stream_live.ex    # EVENTS tab — real-time event log
│       │   │   ├── chat_panel_live.ex      # CHAT tab — color-coded chat viewer
│       │   │   ├── effects_panel_live.ex   # FX tab — effects, titles, entity picker
│       │   │   ├── display_panel_live.ex   # DISPLAY tab — block text, coord fill
│       │   │   └── bot_config_modal_live.ex # Bot config modal — model, personality, behaviors
│       │   ├── controllers/
│       │   └── components/
│       ├── priv/static/
│       └── assets/
└── .env                             # secrets (GROQ_API_KEY, RCON_PASSWORD, etc.)
```

## Supervision Trees

**McFun.Supervisor** (engine — `apps/mc_fun`):
```
├── Phoenix.PubSub (name: McFun.PubSub)
├── McFun.Rcon.Supervisor
├── McFun.World.Redstone.CircuitRegistry
├── McFun.LLM.ModelCache            # ETS + disk cache
├── McFun.CostTracker
├── McFun.ChatLog                   # Persistent chat log (JSONL + ring buffer)
├── McFun.EventStore
└── McFun.LogWatcher                # Polls RCON for player list
```

After start: `McFun.Events.Handlers.register_all()` registers default event handlers.

**BotFarmer.Supervisor** (bot fleet — `apps/bot_farmer`):
```
├── McFun.BotChat                   # Bot-to-bot chat coordinator
├── BotFarmer.BotStore              # Fleet persistence + auto-deploy
├── Registry (McFun.BotRegistry)
└── DynamicSupervisor (McFun.BotSupervisor)
```

**McFunWeb.Supervisor** (web — `apps/mc_fun_web`):
```
├── McFunWeb.Telemetry
├── DNSCluster
└── McFunWeb.Endpoint
```

## Key Patterns

- **BotFarmer facade**: Dashboard code calls `BotFarmer.*` (spawn_bot, stop_bot, set_model, start_patrol, bot_chat_status, etc.) instead of reaching into McFun.Bot/ChatBot/BotBehaviors/BotChat/BotSupervisor directly. Infrastructure modules (Rcon, LLM, Events, World) are still called directly via `McFun.*`.
- **BotStore persistence**: `BotFarmer.BotStore` persists fleet config to `apps/bot_farmer/priv/bot_fleet.json`. On startup, auto-deploys all saved bots (staggered 2s). Writes are debounced (3s). The facade automatically calls BotStore on spawn/stop/config changes.
- **Dashboard LiveComponents**: Each tab is a LiveComponent (`UnitsPanelLive`, `RconConsoleLive`, `EventStreamLive`, `ChatPanelLive`, `EffectsPanelLive`, `DisplayPanelLive`) plus `BotConfigModalLive` for the config modal. Components receive `parent_pid` and communicate back via `send(parent_pid, msg)` for flash/refresh. Cross-tab coord sharing uses `send_update/2`. Function components (`deploy_panel`, `bot_card`) accept a `target` attr for `phx-target` routing.
- **Bot registry keys**: `"BotName"` (Bot), `{:chat_bot, "BotName"}` (ChatBot), `{:behavior, "BotName"}` (BotBehaviors)
- **PubSub topics**: `"bot:#{name}"` for bot events, `McFun.Events` for game events, `"chat_log"` for chat entries
- **ChatLog**: GenServer that subscribes to all bot PubSub + Events, classifies messages (player_chat, whisper, llm_response, heartbeat, bot_to_bot, system), persists to `priv/chat_log.jsonl`, maintains 500-entry ring buffer. Broadcasts `{:new_chat_entry, entry}` on `"chat_log"` topic.
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
- **SNBT parser**: `McFun.SNBT` parses Minecraft's Stringified NBT format into Elixir maps/lists/numbers. Single-pass recursive descent (~230 lines). Returns `{:error, :truncated}` on incomplete input. Used by LogWatcher for player data; available for any `data get entity/block` response. See `docs/nbt.md`.
- **Player data fetching**: Uses `execute as <player> run data get entity @s`, parsed via SNBT. RCON truncates the full blob (~512 chars), so parser returns `:truncated` and LogWatcher falls back to per-field queries (Health, Pos, Dimension, foodLevel). Each field response is short enough to parse fully.

## Environment

- `.env` in repo root — all secrets and config (GROQ_API_KEY, RCON_PASSWORD, RCON_HOST, MC_HOST, etc.)
- `runtime.exs` loads: `.env` → system env (via Dotenvy)
- NEVER delete .env files without reading them first
- Groq API key starts with `gsk_`

## Remote Server

```bash
ssh <mc-server-host>                    # hostname from .env (RCON_HOST)
incus exec minecraft -- <cmd>           # run command in MC container
# Server path inside container: /opt/minecraft/server/
# RCON: port 25575, password <from .env>
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

- `docker-compose.yml` in repo root is for LOCAL dev only, not the primary server
- RCON GenServer crashes the app if auth fails — this is intentional (fail fast)
- `BotSupervisor.list_bots/0` filters registry to binary-only keys to exclude tuples like `{:chat_bot, name}`
- Default LLM model: `openai/gpt-oss-20b` (via Groq)
- `mix precommit` runs compile (warnings-as-errors), deps.unlock --unused, format, credo --strict, test
- All config keys use `:mc_fun` OTP app name (both engine and web config)
