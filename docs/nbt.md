# SNBT Parser — Design Plan

## Problem

We regex-parse Minecraft RCON responses to extract player data. The responses are SNBT (Stringified NBT) — a recursive, typed data format. Regex can't handle nested structures, so we use a fragile two-step fallback: try the full entity blob, fail (truncated by RCON), then issue 4 individual field queries. This is 5 RCON calls per player per 2s poll cycle when 1 would suffice if we could parse the blob properly.

Beyond player data, SNBT appears everywhere in MC commands — inventories, enchantments, block states, mob data. A proper parser unlocks all of it.

## What SNBT Looks Like

Real RCON output from our server:

```
# Full entity (truncated by RCON at ~512 chars)
{Bukkit.updateLevel: 2, foodTickTimer: 0, AbsorptionAmount: 0.0f, XpTotal: 33,
 playerGameType: 0, Invulnerable: 0b, SelectedItemSlot: 3, ...

# Individual field queries (not truncated)
15.68935f                                                    # Health
[-412.3d, 62.0d, 288.4d]                                    # Pos
"minecraft:overworld"                                        # Dimension
17                                                           # foodLevel
[{Slot: 0b, id: "minecraft:stone_pickaxe", count: 1,        # Inventory
  components: {"minecraft:damage": 5}}, {Slot: ...
```

All responses are prefixed with `<Player> has the following entity data: ` which we strip first.

## SNBT Grammar

```
value       = compound | list | byte_array | int_array | long_array | string | number | bool
compound    = "{" (pair ("," pair)* ","?)? "}"
pair        = key ":" value
key         = bare_string | quoted_string
list        = "[" (value ("," value)* ","?)? "]"
byte_array  = "[" "B" ";" (byte  ("," byte)*  ","?)? "]"
int_array   = "[" "I" ";" (int   ("," int)*   ","?)? "]"
long_array  = "[" "L" ";" (long  ("," long)*  ","?)? "]"

string      = quoted_string | bare_string
quoted_string = '"' (escaped_char | [^"\\])* '"'
            | "'" (escaped_char | [^'\\])* "'"
bare_string = [a-zA-Z0-9._+-]+          # unquoted, no spaces/special chars

number      = float | double | long | short | byte | int
float       = [-]?[0-9]*"."?[0-9]+ ("f" | "F")
double      = [-]?[0-9]*"."[0-9]+ ("d" | "D")?   # d suffix optional if has decimal
long        = [-]?[0-9]+ ("l" | "L")
short       = [-]?[0-9]+ ("s" | "S")
byte        = [-]?[0-9]+ ("b" | "B")
int         = [-]?[0-9]+                            # no suffix = int

bool        = "true" → 1b | "false" → 0b           # sugar, stored as byte
```

### Type Suffix Summary

| Suffix | Type   | Elixir representation | Example      |
|--------|--------|----------------------|--------------|
| `b`/`B`| byte   | integer              | `0b`, `127b` |
| `s`/`S`| short  | integer              | `300s`       |
| (none) | int    | integer              | `33`         |
| `l`/`L`| long   | integer              | `1000000L`   |
| `f`/`F`| float  | float                | `20.0f`      |
| `d`/`D`| double | float                | `-412.3d`    |
| (none) | double | float (if has `.`)   | `0.5`        |

### Edge Cases

- Trailing commas allowed: `{a: 1, b: 2,}` is valid
- Keys can be quoted or bare: `"minecraft:damage": 5` vs `Health: 20.0f`
- Keys with dots: `Bukkit.updateLevel` (bare string with `.`)
- Keys with colons: `"minecraft:damage"` (must be quoted if contains `:`)
- Booleans: `true`/`false` are sugar for `1b`/`0b`
- Empty compounds: `{}`
- Empty lists: `[]`
- Nested compounds in lists: `[{Slot: 0b, id: "minecraft:stone"}, ...]`
- Suffixes case-insensitive: `0B` == `0b`, `20.0F` == `20.0f`

## Elixir Representation

```elixir
# SNBT → Elixir mapping
{:compound, %{"Health" => 20.0, "Pos" => [-412.3, 62.0, 288.4], ...}}
{:list, [%{"Slot" => 0, "id" => "minecraft:stone_pickaxe"}, ...]}
{:byte_array, [0, 30]}
{:int_array, [0, -300]}
{:long_array, [0, 240]}

# Or simpler — lose type info, gain usability:
%{"Health" => 20.0, "Pos" => [-412.3, 62.0, 288.4]}
```

**Decision: go simple.** We don't need to round-trip back to SNBT. We need to _read_ MC data into Elixir terms. Drop the type wrappers — compounds become maps, lists become lists, all numbers become integer or float.

```elixir
SNBT.parse(~s|{Health: 20.0f, Pos: [-412.3d, 62.0d, 288.4d], Dimension: "minecraft:overworld"}|)
# => {:ok, %{"Health" => 20.0, "Pos" => [-412.3, 62.0, 288.4], "Dimension" => "minecraft:overworld"}}

SNBT.parse("15.68935f")
# => {:ok, 15.68935}

SNBT.parse(~s|[{Slot: 0b, id: "minecraft:stone_pickaxe", count: 1}]|)
# => {:ok, [%{"Slot" => 0, "id" => "minecraft:stone_pickaxe", "count" => 1}]}
```

## Module Design

```
apps/mc_fun/lib/mc_fun/snbt.ex        # public API + response prefix stripping
apps/mc_fun/lib/mc_fun/snbt/parser.ex  # tokenizer + recursive descent parser
apps/mc_fun/test/mc_fun/snbt_test.exs  # unit tests (no RCON needed)
```

### McFun.SNBT (public API)

```elixir
defmodule McFun.SNBT do
  @moduledoc "Parse Minecraft SNBT (Stringified NBT) into Elixir terms."

  # Parse raw SNBT string
  def parse(snbt)
  # => {:ok, term} | {:error, reason}

  # Parse RCON "data get entity" response (strips player prefix)
  def parse_entity_response(response)
  # => {:ok, term} | {:error, reason}

  # Convenience: parse + get nested path
  def get(snbt, path) when is_binary(snbt)
  def get(parsed, path) when is_map(parsed)
  # path: "Health" or "Inventory.0.id" or ["Inventory", 0, "id"]
  # => {:ok, value} | :error
end
```

### McFun.SNBT.Parser (internal)

Recursive descent parser. No external deps. ~120-150 lines.

```elixir
defmodule McFun.SNBT.Parser do
  # Entry point: parses a full SNBT string into an Elixir term
  def parse(input)  # => {:ok, term, rest} | {:error, reason}

  # Recursive descent functions (all private):
  # parse_value/1     — dispatches based on first char
  # parse_compound/1  — "{" ... "}"
  # parse_list/1      — "[" ... "]" (also handles B;/I;/L; arrays)
  # parse_string/1    — quoted or bare
  # parse_number/1    — with suffix detection
  # skip_whitespace/1 — spaces, tabs, newlines
end
```

**Parser strategy:** Work on a binary, advancing a cursor. No tokenizer pass — single-pass recursive descent. Each `parse_*` function takes a binary, returns `{:ok, value, rest}` where `rest` is the unparsed remainder.

### Key implementation details

1. **Dispatch on first character:**
   - `{` → compound
   - `[` → list or typed array
   - `"` or `'` → quoted string
   - `-` or digit → number
   - `t`/`f` → maybe boolean, then bare string fallback
   - anything else → bare string

2. **Number parsing:** Read digits, check suffix. Tricky part: `0b` could be byte 0 or start of a bare string. Context: if we're reading a value (after `:` or in a list), it's a byte. In practice MC always uses numeric-only before `b`.

3. **Truncation handling:** The full entity blob gets cut off by RCON mid-value. Parser will hit unexpected EOF → return `{:error, :truncated}`. Caller falls back to field queries. This replaces the current "parse then check for nil" heuristic with a clean signal.

4. **String keys:** Bare strings end at `:`, `,`, `}`, `]`, or whitespace. Quoted strings handle `\"` escapes.

## Integration with LogWatcher

```elixir
# Before (current — 5 RCON calls, regex, fallback)
defp fetch_single_player_data(player) do
  case McFun.Rcon.command("execute as #{player} run data get entity @s") do
    {:ok, response} ->
      data = parse_entity_data(response)  # regex, usually fails
      if data.health == nil, do: fetch_player_data_fields(player), else: data
    {:error, _} -> fetch_player_data_fields(player)
  end
end

# After (1 RCON call when not truncated, 5 as fallback)
defp fetch_single_player_data(player) do
  case McFun.Rcon.command("execute as #{player} run data get entity @s") do
    {:ok, response} ->
      case McFun.SNBT.parse_entity_response(response) do
        {:ok, data} when is_map(data) ->
          %{
            health: data["Health"],
            food: data["foodLevel"],
            position: parse_pos(data["Pos"]),
            dimension: data["Dimension"]
          }

        {:error, :truncated} ->
          # RCON cut off the response — fall back to individual queries
          fetch_player_data_fields(player)

        {:error, reason} ->
          Logger.warning("SNBT parse failed: #{inspect(reason)}")
          fetch_player_data_fields(player)
      end

    {:error, reason} ->
      Logger.warning("Entity data command failed for #{player}: #{inspect(reason)}")
      fetch_player_data_fields(player)
  end
end
```

## Future Uses (once parser exists)

- **Inventory inspection**: `data get entity @s Inventory` → full item list with enchantments
- **Block state reading**: `data get block x y z` → block entity data (chests, signs, etc.)
- **Mob data**: `data get entity @e[type=zombie,limit=1]` → mob stats
- **Structure commands**: Parse `/setblock` and `/fill` NBT arguments
- **ChatBot context**: Give LLM structured inventory/equipment data instead of raw survey

## Test Plan

Unit tests only — no RCON needed. Test against real MC output strings.

```elixir
# Scalars
assert SNBT.parse("20.0f") == {:ok, 20.0}
assert SNBT.parse("0b") == {:ok, 0}
assert SNBT.parse("33") == {:ok, 33}
assert SNBT.parse("1000000L") == {:ok, 1_000_000}
assert SNBT.parse(~s|"minecraft:overworld"|) == {:ok, "minecraft:overworld"}

# Compound
assert SNBT.parse("{Health: 20.0f, foodLevel: 20}") ==
  {:ok, %{"Health" => 20.0, "foodLevel" => 20}}

# Nested
assert SNBT.parse(~s|{Pos: [-412.3d, 62.0d, 288.4d], Dimension: "minecraft:overworld"}|) ==
  {:ok, %{"Pos" => [-412.3, 62.0, 288.4], "Dimension" => "minecraft:overworld"}}

# Inventory (list of compounds)
assert {:ok, [%{"Slot" => 0, "id" => "minecraft:stone_pickaxe"} | _]} =
  SNBT.parse(~s|[{Slot: 0b, id: "minecraft:stone_pickaxe", count: 1}]|)

# Typed arrays
assert SNBT.parse("[I; 1, 2, 3]") == {:ok, [1, 2, 3]}
assert SNBT.parse("[B; 0b, 30b]") == {:ok, [0, 30]}

# Truncation
assert SNBT.parse("{Health: 20.0f, Pos: [-412.3d, 62.0d") == {:error, :truncated}

# Edge cases
assert SNBT.parse("{a: 1, b: 2,}") == {:ok, %{"a" => 1, "b" => 2}}  # trailing comma
assert SNBT.parse("{}") == {:ok, %{}}
assert SNBT.parse("[]") == {:ok, []}
assert SNBT.parse("true") == {:ok, 1}   # boolean sugar
assert SNBT.parse("false") == {:ok, 0}

# Entity response prefix
assert SNBT.parse_entity_response("Steve has the following entity data: 20.0f") ==
  {:ok, 20.0}
```

## Implementation Order

1. `McFun.SNBT.Parser` — recursive descent, scalars first, then compounds/lists
2. `McFun.SNBT` — public API, prefix stripping, path access
3. `snbt_test.exs` — unit tests against real MC output
4. Integrate into LogWatcher — replace regex parsers
5. Clean up dead regex code in LogWatcher
