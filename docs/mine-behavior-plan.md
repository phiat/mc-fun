# Mine Behavior — Architecture Plan

Feature issue: mc-fun-49

## Overview

Add autonomous mining behavior to bots. A bot can be told to mine a specific block type (e.g., `diamond_ore`, `oak_log`) and will continuously find → pathfind → dig until stopped, max count reached, or 3 consecutive failures.

## Design Principles

- **Additive only** — no modifications to existing behavior patterns
- **Follows existing conventions** — mirrors patrol/follow/guard pattern exactly
- **Configurable** — block type, max distance, max count all parameterized
- **Resilient** — consecutive failure auto-stop, tool priority respect, timeout handling

## Components (5 files, ~270 new lines)

### 1. bridge.js — `find_blocks` command (~40 LOC)

New command in `handleCommand` switch that wraps `bot.findBlocks()`:

```javascript
case 'find_blocks':
  const mcData = require('minecraft-data')(bot.version);
  const blockType = mcData.blocksByName[cmd.block_type];
  if (!blockType) {
    send({ event: 'error', action: 'find_blocks', message: `Unknown block: ${cmd.block_type}` });
    break;
  }
  const blocks = bot.findBlocks({
    matching: blockType.id,
    maxDistance: cmd.max_distance || 32,
    count: Math.min(cmd.count || 10, 100)
  });
  send({
    event: 'find_blocks_result',
    blocks: blocks.map(pos => ({
      x: pos.x, y: pos.y, z: pos.z,
      distance: bot.entity.position.distanceTo(pos)
    })),
    total: blocks.length
  });
  break;
```

### 2. Bot.ex — `find_blocks/3` API (~30 LOC)

Synchronous wrapper mirroring `survey/1` pattern:

```elixir
def find_blocks(bot_name, block_type, opts \\ []) do
  max_distance = Keyword.get(opts, :max_distance, 32)
  count = Keyword.get(opts, :count, 10)
  GenServer.call(via(bot_name), {:find_blocks, block_type, max_distance, count}, 10_000)
catch
  :exit, _ -> {:error, :not_found}
end
```

With corresponding `handle_call` and `find_blocks_result` event handler using the listener pattern.

### 3. BotBehaviors.ex — `:mine` behavior (~100 LOC)

Public API:
```elixir
def start_mine(bot_name, block_type, opts \\ [])
```

State in params:
```elixir
%{
  block_type: String.t(),
  max_distance: pos_integer(),       # default 32
  max_count: pos_integer() | nil,    # nil = unlimited
  mined_count: non_neg_integer(),
  consecutive_failures: 0..3,
  last_block_pos: {x, y, z} | nil
}
```

Tick logic (`execute_behavior(:mine)`):
1. Check tool priority — skip tick if bot has active tool action
2. Call `Bot.find_blocks(bot, block_type, count: 1)`
3. No blocks → increment `consecutive_failures`, chat status
4. Block found → `Bot.send_command(:goto)`, then `:dig` on completion
5. Dig done → increment `mined_count`, reset `consecutive_failures`
6. Auto-stop conditions: `mined_count >= max_count` or `consecutive_failures >= 3`

### 4. ChatBot — `mine_block` tool (~20 LOC)

Tool definition for LLM invocation:
- Params: `block_type` (required), `max_count` (optional), `max_distance` (optional)
- Maps to `BotBehaviors.start_mine/3`
- Tool-capable models only (no regex fallback needed)

### 5. Dashboard — mine behavior form (~80 LOC)

Form in BOTS tab alongside patrol/follow/guard:
- Block type text input
- Max distance number input (default 32)
- Max count number input (optional)
- Start/Stop buttons
- Status display: "Mining diamond_ore (5/20)"

## Data Flow

```
Dashboard "Start Mine" → BotBehaviors.start_mine("Bot1", "coal_ore", max_count: 10)
  → GenServer starts, subscribes to "bot:Bot1"
  → Tick 1: find_blocks → bridge searches → [block found at {100, 64, 200}]
  → Tick 2: goto {100, 64, 200} → pathfinder navigates
  → goto_done event → dig {100, 64, 200}
  → dig_done event → mined_count: 1, consecutive_failures: 0
  → Tick 3: find_blocks → next block...
  → ... repeat until mined_count == 10
  → Bot.chat("Mining complete! Mined 10 coal_ore.")
  → Behavior stops itself
```

## Error Handling

| Scenario | Response |
|----------|----------|
| No blocks found | Increment failures (1/3), chat status, try again next tick |
| 3 consecutive failures | Auto-stop, chat "no more {block} in range" |
| Block disappeared | Count as failure, next tick searches fresh |
| Pathfind timeout (15s) | Skip block, increment failure |
| Port dead | Log error, chat, stop behavior |
| Tool action active | Skip tick, schedule next (respects tool priority) |

## Build Sequence

1. **Bridge.js** `find_blocks` command (foundational)
2. **Bot.ex** `find_blocks/3` wrapper API
3. **BotBehaviors** mine logic (core)
4. **ChatBot** tool integration
5. **Dashboard** UI form
6. **Tests & docs**

## Common Block Types

**Ores:** `coal_ore`, `iron_ore`, `gold_ore`, `diamond_ore`, `emerald_ore`, `redstone_ore`, `lapis_ore` (+ `deepslate_*` variants)

**Logs:** `oak_log`, `birch_log`, `spruce_log`, `jungle_log`, `acacia_log`, `dark_oak_log`

**Stone:** `stone`, `cobblestone`, `granite`, `diorite`, `andesite`, `deepslate`

## Future Enhancements

- **Vein mining** — dig all connected blocks of same type (BFS)
- **Tool requirement** — `require_tool: true` to stop if no appropriate tool
- **Auto-equip** — equip best tool before digging
- **Layer restrictions** — `only_layers: [y: 5..15]` for diamond mining
- **Return on full inventory** — pathfind to chest, deposit, return
- **Progress chat** — configurable interval (every N blocks)
