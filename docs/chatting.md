# Bot Chat System

How bots talk — to players, to each other, and to themselves.

## Architecture Overview

Three modules collaborate:

| Module | Role | Lives in |
|--------|------|----------|
| `McFun.ChatBot` | Per-bot GenServer. LLM calls, conversation history, heartbeat, commands. | bot_farmer |
| `McFun.ChatBot.Tools` | Tool definitions + execution dispatch for LLM function calling. | bot_farmer |
| `McFun.ChatBot.Context` | Survey/status/chat context builder for LLM prompts. | bot_farmer |
| `McFun.ChatBot.TextFilter` | CoT stripping, text chunking, paginated send. | bot_farmer |
| `McFun.FleetChat` | Singleton coordinator. Bot-to-bot routing, topic injection, dedup. | bot_farmer |
| `McFun.BotBehaviors` | Per-bot GenServer. Patrol/follow/guard/mine tick loops. | bot_farmer |

```
Player chats in MC
       │
       ▼
  bridge.js (mineflayer 'chat' event)
       │
       ▼
  Bot.ex (Erlang Port) ── broadcasts {:bot_event, bot_name, event} on "bot:#{name}"
       │
       ├──► ChatBot (subscribes to own bot's topic)
       │       handles !commands, whispers, LLM responses
       │
       └──► FleetChat (subscribes to ALL bot topics)
               routes bot-to-bot chat, topic injection, dedup
```

## ChatBot — Per-Bot LLM Agent

Registered as `{:chat_bot, "BotName"}` in `McFun.BotRegistry`.

### State

```elixir
%ChatBot{
  bot_name: "Bogo",
  personality: "You are a friendly...",
  model: "openai/gpt-oss-20b",
  conversations: %{"PlayerName" => [{:player, "hi"}, {:bot, "hello!"}]},
  last_active: %{"PlayerName" => monotonic_ms},
  last_response: monotonic_ms | nil,    # rate limiting (2s cooldown)
  last_message: "last stripped reply",   # dedup
  heartbeat_ref: ref | nil,
  heartbeat_enabled: true,
  group_chat_enabled: true               # allows bot-to-bot responses
}
```

### Message Flow

```
                    ┌─────────────────────────────────────────────┐
                    │              ChatBot GenServer               │
                    │                                             │
  !ask question ───►│ handle_message/4 ──► spawn_response/3       │
  !model id    ───►│   (rate limited)        │                   │
  !personality ───►│                    Task.start_link ──► Groq  │
  !reset       ───►│                         │                   │
  !tp          ───►│                         ▼                   │
  whisper      ───►│              {:llm_response, ...}           │
                    │                    │         │              │
                    │              with tools   text only         │
                    │                    │         │              │
                    │          Tools.execute  ActionParser.parse  │
                    │           + chat reply  + chat reply        │
                    └─────────────────────────────────────────────┘
```

### Player Commands (in-game)

| Command | Action |
|---------|--------|
| `!ask <question>` | LLM query (rate-limited 2s) |
| `!model <id>` | Switch Groq model (fuzzy match) |
| `!models` | List available models |
| `!personality <text>` | Change system prompt |
| `!reset` | Clear conversation history |
| `!tp` / `!tp <target>` | Teleport to player/target |
| Whisper (any text) | Always triggers LLM response (whispers back) |

Regular chat without `!` prefix is ignored by ChatBot — it's handled by FleetChat for bot-to-bot conversations.

### Tool Calling

Models with tool support (llama, qwen, openai/, meta-llama/, moonshotai/) use Groq function calling. The LLM can invoke:

`goto_player`, `follow_player`, `dig`, `find_and_dig`, `dig_area`, `look`, `jump`, `attack`, `drop`, `drop_item`, `drop_all`, `sneak`, `craft`, `equip`, `activate_block`, `use_item`, `sleep`, `wake`, `stop`

Models without tool support fall back to `McFun.ActionParser` — regex matching on trigger phrases like "on my way" → goto, "I'll dig" → dig. ActionParser passes `source: :action_parser` so actions are tracked on the dashboard.

If the LLM returns tool calls with no text, a follow-up LLM call generates a witty acknowledgement.

### Thinking Strip

Reasoning models emit chain-of-thought before the actual reply. `TextFilter.strip_thinking/1` handles this with a cascade of strategies:

1. **`REPLY:` marker** — most reliable. Takes everything after the marker.
2. **CoT pattern detection** — matches starts like "The ", "We ", "I need", "Let me", "Since ", etc. Then tries:
   a. Extract complete quoted text (`"..."` or `"..."`)
   b. Find text after markers like "like:", "say:", "response:"
   c. Take the last paragraph (separated by double newlines)
   d. If all fail and the last part still looks like reasoning, suppress entirely (return `""`)
3. Otherwise returns text as-is

The suppression fallback (2d) prevents CoT from leaking into public chat when the LLM's reply is truncated by max_tokens before a closing quote.

### Conversation Management

- Max 20 messages per player history (ring buffer)
- Max 50 concurrent player conversations
- Conversations expire after 1 hour of inactivity (TTL eviction)
- Oldest conversations evicted when over cap

### Chat Pagination

Responses are chunked at word boundaries via `TextFilter.send_paginated/4`: 180 chars/line, max 4 lines, 300ms delay between lines. Whisper responses are whispered back; everything else is public chat.

## Heartbeat — Ambient Chat

Each ChatBot periodically "thinks out loud" — a random prompt triggers an LLM call that produces a 1-2 sentence observation.

### Timing

| State | Interval | Env var |
|-------|----------|---------|
| Bot has active behavior (patrol/mine/etc) | 15s | `CHATBOT_HEARTBEAT_BEHAVIOR_MS` |
| Bot is idle | 120s | `CHATBOT_HEARTBEAT_IDLE_MS` |
| Cooldown after player conversation | 10s skip | `CHATBOT_HEARTBEAT_COOLDOWN_MS` |

### Heartbeat Prompts

Built-in prompts (shared between ChatBot and FleetChat for filtering):
- "What are you doing right now? Give a quick update."
- "What's something interesting you notice around you?"
- "What's on your mind right now?"
- "Share a random fun fact related to what you see."
- "Freestyle a quick 2-line rap about your situation."
- "What would you suggest doing next around here?"
- "Rate your current mood on a scale and explain why."
- "Describe your surroundings like a nature documentary narrator."

Heartbeat messages are filtered out by FleetChat to prevent bot-to-bot response chains on ambient chat.

## FleetChat — Bot-to-Bot Coordinator

Singleton GenServer (`McFun.FleetChat`). Subscribes to all active bot PubSub topics (refreshes every 5s).

### State

```elixir
%{
  enabled: true,                          # main toggle
  config: %{
    proximity: 32,                        # blocks — bots must be this close
    max_exchanges: 3,                     # exchanges before cooldown
    cooldown_ms: 60_000,                  # 1min cooldown per pair
    response_chance: 0.7,                 # 70% chance to respond
    min_delay_ms: 2_000,                  # min delay before response
    max_delay_ms: 5_000,                  # max delay before response
    topic_interval_ms: 300_000            # 5min between auto topic injections
  },
  pairs: %{{bot_a, bot_b} => %{count: 0, cooldown_until: nil, last_at: nil}},
  custom_topics: ["Elixir and the joy of the BEAM"],
  disabled_topics: MapSet<["Hey, what do you think about this area?", ...]>,
  topic_injection_enabled: false,         # auto-inject toggle
  topic_timer_ref: ref | nil,
  subscribed_bots: MapSet<["Bogo", "Mindy"]>,
  pending_responses: MapSet<["Mindy"]>,   # bots with scheduled responses
  recent_whispers: %{{username, msg} => {bot_name, timestamp}},
  recent_chats: %{{speaker, msg} => timestamp}  # dedup (5s TTL)
}
```

### Bot-to-Bot Response Chain

```
Bogo says "I love diamonds!" (public chat)
    │
    ▼
bridge.js on every other bot hears it
    │
    ▼
Bot.ex broadcasts {:bot_event, listener_name, %{event: "chat", username: "Bogo", ...}}
    │
    ▼
FleetChat receives N copies (one per listener bot)
    │  deduplicates via recent_chats map (5s TTL)
    │  uses "username" field as actual speaker (not listener)
    ▼
maybe_trigger_response(state, "Bogo", message, known_bots)
    │
    │  Finds candidates: other bots that are:
    │    ✓ alive (ChatBot registered)
    │    ✓ group_chat_enabled
    │    ✓ nearby (within proximity blocks)
    │    ✓ not already pending
    │    ✓ pair not in cooldown or over max_exchanges
    │
    │  Rolls response_chance (70%, +20% if bot name mentioned)
    │
    ▼
Picks one random responder, schedules delayed response (2-5s)
    │
    ▼
{:trigger_response, "Mindy", "Bogo", message}
    │
    ▼
ChatBot.inject_bot_message("Mindy", "Bogo", message)
    │  adds to Mindy's conversation history under "Bogo"
    │  spawns LLM response Task
    │
    ▼
Mindy chats publicly → cycle repeats up to max_exchanges (3)
    then pair enters cooldown (60s)
```

### Pair Tracking

Pairs are keyed as `{min(a,b), max(a,b)}` for symmetry. Each pair tracks:
- `count` — exchanges in current burst
- `cooldown_until` — monotonic ms when cooldown expires
- `last_at` — last exchange timestamp

When `count >= max_exchanges`, pair resets count to 0 and enters cooldown.

### Whisper Dedup

All bots hear all whispers from mineflayer. `FleetChat.claim_whisper/3` ensures only one bot responds to each unique `{username, message}` pair (5s TTL). First bot to claim wins.

## Topic Injection

Injects a conversation starter to get bots talking to each other.

### Flow

```
Timer fires (every 5min) or UI "INJECT NOW" clicked
    │
    ▼
do_inject_topic(state)
    │
    │  Merge default_topics + custom_topics
    │  Filter out disabled_topics
    │  Filter bots to those with ChatBot attached
    │  Prefer bots with nearby peers (group_chat_enabled)
    │
    ▼
inject_topic_if_ready — picks up to 3 bots, staggered:
    │  Bot 1: immediate  ChatBot.inject_topic(bot1, topic)
    │  Bot 2: 3-6s delay  {:delayed_topic_inject, bot2, topic}
    │  Bot 3: 6-12s delay {:delayed_topic_inject, bot3, topic}
    │
    ▼ (each bot independently)
handle_cast({:inject_topic, topic})
    │  Broadcasts activity_change "thinking"
    │  Spawns Task:
    │    survey for environment context
    │    LLM call with topic prompt (own unique take, not echo)
    │    sends {:topic_response, result} back
    │
    ▼
handle_info({:topic_response, {:ok, text}})
    │  Broadcasts activity_change "chatting"
    │  strip_thinking → send_paginated (public chat)
    │  Broadcasts activity_change nil (idle)
    │  sets last_response (suppresses heartbeat)
    │  broadcasts llm_response event with "topic" tag
```

Each bot generates its own response independently, so the conversation doesn't rely on the chat relay chain to propagate.

### Default Topics

10 built-in conversation starters:
- "Hey, what do you think about this area?"
- "I wonder what's in that cave over there..."
- "Anyone want to go mining?"
- "What's the best thing you've found today?"
- "I think I heard something nearby..."
- "This is a nice spot, don't you think?"
- "Want to build something together?"
- "I bet I can find diamonds before you!"
- "Have you seen any cool structures around here?"
- "What should we do next?"

Custom topics can be added/removed via the dashboard or `FleetChat.add_topic/1`.
Individual topics can be enabled/disabled via `FleetChat.toggle_topic/2`.

### Requirements for Topic Injection to Work

All of these must be true:

1. **FleetChat coordinator enabled** — main toggle (default: true)
2. **Topic injection AUTO ON** — or clicking INJECT NOW (default: false)
3. **At least 1 bot deployed** with ChatBot attached (works with 1+, but 2+ is better for conversation)
4. **Bots have group chat enabled** — needed for peer detection
5. **Bots within proximity** (default 32 blocks) — preferred for `bot_nearby?` check (falls back to any eligible bot)
6. **At least one enabled topic** — defaults or custom, not all disabled

## BotBehaviors — Autonomous Actions

Per-bot GenServer registered as `{:behavior, "BotName"}`. One behavior per bot — starting a new one stops the old.

### Behaviors

| Behavior | Tick Action | Params |
|----------|-------------|--------|
| `:patrol` | Cycles through waypoints, sends `goto` each tick | `waypoints: [{x,y,z}, ...]` |
| `:follow` | Sends `follow` toward target player each tick | `target: "PlayerName"` |
| `:guard` | Sends `goto` back to guard position each tick | `position: {x,y,z}, radius: 8` |
| `:mine` | Sends `find_and_dig` for block type each tick | `block_type: "iron_ore", max_count: 64, mined: 0` |

### Tick Loop

Every 1 second:
1. Check `Bot.current_action` — if a `:tool` action is active, **skip tick** (tools take priority)
2. Otherwise execute the behavior's command with `source: :behavior`

Commands sent with `source: :behavior` are tracked by Bot.ex for activity display but don't reset `started_at` if the same action is already running (prevents timestamp churn from 1s ticks).

### Mine Completion

Mine behavior tracks blocks mined via `find_and_dig_done` PubSub events. When `mined >= max_count`, the behavior announces completion in chat and stops itself.

## Presets — Bot Personalities

22 personality presets across 6 categories, defined in `McFun.Presets`:

| Category | Presets |
|----------|---------|
| `:minecraft` | Villager Bob, The Ender, Witch Zelda, Creeper Carl |
| `:classic` | Pirate Pete, Wizard Zara, Robot X-7, Detective Noir |
| `:modern` | Streamer Star, Food Critic, Tech Bro, Conspiracy Carl |
| `:absurd` | Time Traveler, Ghost Bot, Dramatic Narrator, Evil Genius |
| `:cultural` | Haiku Master, Shakespearean, Surfer Dude, Viking Ragnar |
| `:meta` | Bug Reporter, Philosopher |

Each preset includes: `id`, `name`, `category`, `description`, `system_prompt`, `traits` map, `temperature`.

Access via `McFun.Presets.all/0`, `by_category/0`, `get/1`.

## Configuration

### ChatBot Config (`:mc_fun, :chat_bot`)

| Key | Default | Env var |
|-----|---------|---------|
| `default_personality` | "You are a friendly..." | `CHATBOT_DEFAULT_PERSONALITY` |
| `heartbeat_behavior_ms` | 15000 | `CHATBOT_HEARTBEAT_BEHAVIOR_MS` |
| `heartbeat_idle_ms` | 120000 | `CHATBOT_HEARTBEAT_IDLE_MS` |
| `heartbeat_cooldown_ms` | 10000 | `CHATBOT_HEARTBEAT_COOLDOWN_MS` |
| `followup_max_tokens` | 256 | `CHATBOT_FOLLOWUP_MAX_TOKENS` |
| `heartbeat_max_tokens` | 128 | `CHATBOT_HEARTBEAT_MAX_TOKENS` |
| `max_response_tokens` | 1024 | `CHATBOT_MAX_RESPONSE_TOKENS` |

### FleetChat Config (`:mc_fun, :bot_chat`)

| Key | Default | Env var |
|-----|---------|---------|
| `enabled` | true | `BOT_CHAT_ENABLED` |
| `proximity` | 32 | `BOT_CHAT_PROXIMITY` |
| `max_exchanges` | 3 | `BOT_CHAT_MAX_EXCHANGES` |
| `cooldown_ms` | 60000 | `BOT_CHAT_COOLDOWN_MS` |
| `response_chance` | 0.7 | `BOT_CHAT_RESPONSE_CHANCE` |
| `min_delay_ms` | 2000 | `BOT_CHAT_MIN_DELAY_MS` |
| `max_delay_ms` | 5000 | `BOT_CHAT_MAX_DELAY_MS` |
| `topic_interval_ms` | 300000 | `BOT_CHAT_TOPIC_INTERVAL_MS` |
| `topic_injection_enabled` | false | `BOT_CHAT_TOPIC_INJECTION` |

### Constants (code-level)

| Constant | Value | Location |
|----------|-------|----------|
| `@rate_limit_ms` | 2000 | ChatBot |
| `@max_history` | 20 | ChatBot |
| `@max_players` | 50 | ChatBot |
| `@conversation_ttl_ms` | 1 hour | ChatBot |
| `@chat_line_length` | 180 chars | ChatBot.TextFilter |
| `@max_chat_lines` | 4 | ChatBot.TextFilter |
| `@tick_interval` | 1000ms | BotBehaviors |
| `@follow_distance` | 3 blocks | BotBehaviors |
| `@guard_radius` | 8 blocks | BotBehaviors |
| `@mine_max_distance` | 32 blocks | BotBehaviors |
| `@refresh_interval_ms` | 5000ms | FleetChat |
