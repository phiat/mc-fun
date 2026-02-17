# MC Fun -- Project Summary

## Executive Summary

MC Fun is an Elixir/Phoenix umbrella application that serves as a real-time control panel for a remote Minecraft server. It connects to the server over RCON (the Minecraft remote console protocol) and deploys AI-powered bots into the game world using mineflayer, a Node.js Minecraft client library. The system is split into three OTP applications: `mc_fun` (engine -- RCON, LLM client, event system, world manipulation), `bot_farmer` (bot fleet management -- spawning, AI chat, behaviors, persistence), and `mc_fun_web` (Phoenix LiveView dashboard with tabbed UI for controlling everything from a browser).

The bots are the core feature. Each bot is an Erlang Port wrapping a Node.js process that runs mineflayer, communicating via newline-delimited JSON over stdin/stdout. Bots have LLM-powered personalities (via Groq API), can respond to player chat, whisper privately, execute physical actions in the game (dig, follow, craft, navigate), and hold multi-turn conversations with per-player history. Multiple bots can talk to each other through a proximity-based coordinator (`McFun.BotChat`) that manages cooldowns, exchange limits, and topic injection. The dashboard provides real-time visibility into bot status, player data, chat logs, LLM costs, RCON commands, and in-game effects -- all streamed over Phoenix PubSub and LiveView websockets.

The project has no database. All state lives in GenServers, ETS tables, and JSON files on disk. Bot fleet configurations persist to `bot_fleet.json` and auto-deploy on startup. LLM costs persist to `cost_data.json`. Chat history is a JSONL ring buffer. This keeps the operational footprint minimal -- `mix phx.server` is the only command needed to run the entire system.

## Technical Challenges & Solutions

- **Cross-runtime bridge (Elixir <-> Node.js)**: Each bot spawns a Node.js child process via `Port.open/2`. Commands flow as JSON lines over stdin; events come back over stdout. The bridge (`bridge.js`, ~990 lines) handles 25+ action types with an async command queue, timeout wrappers, and pathfinder fallbacks. `McFun.Bot` checks `Port.info/1` before every send to avoid writing to dead ports.

- **RCON connection pooling**: The Minecraft server only supports a handful of concurrent RCON connections. `McFun.Rcon` splits traffic into a dedicated interactive lane (for user commands) and a round-robin poll pool (for `LogWatcher` background queries). Pool rotation uses `:atomics.add_get/3` for lock-free counter increment.

- **Remote server event detection without log access**: The MC server runs in an Incus/LXC container on a separate host -- no local log file to tail. `McFun.LogWatcher` polls RCON `list` every 2 seconds, diffs `MapSet`s to detect joins/leaves, and fires events through `McFun.Events`. First poll silently populates the player set to avoid spurious join events on app restart.

- **SNBT parsing**: Minecraft's `data get entity` responses use SNBT (Stringified NBT), a format with no off-the-shelf Elixir parser. `McFun.SNBT.Parser` is a ~230-line single-pass recursive descent parser handling compounds, typed arrays (`[I;`, `[B;`, `[L;`), quoted strings, number suffixes (`3.14f`, `42L`), booleans, and bare strings. Returns `{:error, :truncated}` gracefully when RCON cuts off the response at ~512 chars.

- **RCON truncation workaround**: Full entity data blobs exceed RCON's response limit. When `parse_entity_response/1` returns `:truncated`, `LogWatcher` falls back to per-field queries (`Health`, `Pos`, `Dimension`, `foodLevel`), each short enough to parse completely.

- **Whisper deduplication**: Every bot receives every whisper event from mineflayer. Without coordination, all bots would respond. `McFun.BotChat.claim_whisper/3` implements first-come-first-served claiming with a 5-second TTL map -- only the first bot to claim a `{username, message}` pair responds.

- **LLM tool calling with fallback**: Models that support OpenAI-style function calling (llama, qwen, openai/, meta-llama/) get a structured tool schema with 18 tools. Models without tool support fall back to `McFun.ActionParser`, a regex-based system that detects trigger phrases ("on my way", "I'll dig") in the LLM's natural language response and maps them to bot actions.

- **Chain-of-thought stripping**: Reasoning models include internal thinking in their output. `ChatBot.strip_thinking/1` looks for a `REPLY:` marker, falls back to quoted-text extraction for CoT patterns, and passes through clean responses unchanged.

- **Bot-to-bot conversation control**: `McFun.BotChat` prevents infinite chat loops with per-pair exchange limits (configurable max exchanges before cooldown), probabilistic response chance (boosted when a bot's name is mentioned), random delays (2-5s) for natural pacing, and proximity checks using 3D Euclidean distance between bot positions.

- **Action priority and source tracking**: Bot actions carry a `:source` tag (`:tool` from LLM tool calls, `:behavior` from patrol/guard loops). Tool-initiated actions take priority -- behavior ticks are suppressed while a tool action is running. Action completion events from bridge.js clear the tracking state and broadcast to the dashboard.

## Notable Implementation Details

- **`McFun.Bot` struct tracks live state from bridge events**: Position, health, food, dimension, inventory, and current action are all updated in-process from the JSON event stream. No polling required for bot-side state -- only the 3s position poll and 5s inventory poll exist as consistency checks.

- **`bridge.js` command queue**: Async actions (dig, goto, craft) are serialized through an `actionBusy` flag and queue. Sync actions (chat, look, position) bypass the queue entirely. The `onGoalReached` helper manages pathfinder goal listeners with timeout and cleanup tracking to prevent listener leaks across reconnections.

- **Reconnection with exponential backoff in bridge.js**: On disconnect or kick, the bridge schedules reconnection with exponential backoff (1s, 2s, 4s... up to 30s, max 10 attempts). Fatal kicks (whitelist/ban) exit immediately. All async state (goal listeners, dig_area progress, movement timers) is cleaned up on disconnect.

- **`McFun.CostTracker`**: ETS-backed cost tracking with per-model Groq pricing tables. Computes cost from `prompt_tokens * input_price + completion_tokens * output_price`. Debounces disk writes (5s). Broadcasts updates over PubSub so the dashboard shows live cost accumulation.

- **`McFun.ChatBot` heartbeat system**: Bots periodically generate ambient chat using random prompts ("What are you doing right now?", "Describe your surroundings like a nature documentary narrator"). Heartbeat interval adapts based on whether the bot has an active behavior (shorter interval when patrolling vs. idle). Heartbeats are suppressed during active player conversations via a cooldown check.

- **`McFun.ActionParser` priority ordering**: Regex patterns are ordered by priority -- dig before follow, follow before goto. Only the first match is taken to avoid conflicting simultaneous actions (e.g., "I'll dig on my way" should dig, not walk).

- **`McFun.World.Effects`**: Constructs raw SNBT-encoded RCON commands for fireworks (with configurable colors, shapes, flight duration), particles, sounds, and titles. Preset combos (`celebration`, `welcome`, `death_effect`) sequence multiple effects with timing delays.

- **Dashboard LiveView architecture**: `DashboardLive` is a lightweight parent that manages PubSub subscriptions, tab routing, and shared state. Each tab is a `LiveComponent` that receives a `parent_pid` for flash messages and cross-tab coordination. Bot subscription management is dynamic -- the parent subscribes to new bots and unsubscribes from dead ones every 3 seconds.

- **Survey as synchronous call**: `McFun.Bot.survey/1` is the only blocking call to bridge.js. It stores the caller in a `listeners` list, sends the survey command, and replies when the survey event arrives. This gives the LLM a snapshot of nearby blocks, entities, inventory, and vitals before generating each response.

- **Paginated chat output**: `ChatBot.send_paginated/2` chunks LLM responses at word boundaries (180 chars/line, max 4 lines, 300ms delay between) to stay within Minecraft's chat display limits.

- **`BotFarmer.BotStore` auto-deploy**: Fleet configuration persists to JSON. On startup, all saved bots are spawned with 2-second stagger to avoid overwhelming the MC server. Config writes are debounced at 3 seconds. The `BotFarmer` facade automatically triggers persistence on spawn, stop, and config changes.
