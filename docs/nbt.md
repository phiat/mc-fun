# SNBT Parser

`McFun.SNBT` — a single-pass recursive descent parser for Minecraft's Stringified NBT format. Parses RCON `data get entity` responses into native Elixir terms. No external dependencies.

## Files

```
apps/mc_fun/lib/mc_fun/snbt.ex         # Public API: parse/1, parse_entity_response/1, get/2
apps/mc_fun/lib/mc_fun/snbt/parser.ex   # Recursive descent parser (~230 lines)
apps/mc_fun/test/mc_fun/snbt_test.exs   # 42 unit tests (no RCON needed)
```

## Usage

```elixir
# Parse any SNBT string
McFun.SNBT.parse("{Health: 20.0f, foodLevel: 20}")
# => {:ok, %{"Health" => 20.0, "foodLevel" => 20}}

McFun.SNBT.parse("15.68935f")
# => {:ok, 15.68935}

McFun.SNBT.parse("[I; 1, 2, 3]")
# => {:ok, [1, 2, 3]}

# Parse RCON response (strips "Player has the following entity data: " prefix)
McFun.SNBT.parse_entity_response("Steve has the following entity data: 20.0f")
# => {:ok, 20.0}

# Dot-path access into parsed data
{:ok, data} = McFun.SNBT.parse(~s|{Pos: [1.0d, 2.0d, 3.0d]}|)
McFun.SNBT.get(data, "Pos.0")
# => {:ok, 1.0}

# List path syntax
McFun.SNBT.get(data, ["Pos", 0])
# => {:ok, 1.0}

# Truncated input (RCON cuts off large responses)
McFun.SNBT.parse("{Health: 20.0f, Pos: [-412.3d, 62.0d")
# => {:error, :truncated}
```

## How LogWatcher Uses It

LogWatcher polls RCON every 2s for player data. The flow:

1. Send `execute as <player> run data get entity @s`
2. RCON returns full entity NBT — but truncates at ~512 chars
3. SNBT parser returns `{:error, :truncated}`
4. Fall back to individual field queries: `... data get entity @s Health`, etc.
5. Each field response is short enough to parse fully

```elixir
# Full entity (truncated by RCON — parser detects cleanly)
"{Bukkit.updateLevel: 2, foodTickTimer: 0, AbsorptionAmount: 0.0f, ..."
# => {:error, :truncated}

# Individual fields (not truncated — parse succeeds)
"15.68935f"                                                → {:ok, 15.68935}
"[-412.3d, 62.0d, 288.4d]"                                → {:ok, [-412.3, 62.0, 288.4]}
"\"minecraft:overworld\""                                  → {:ok, "minecraft:overworld"}
"17"                                                       → {:ok, 17}
```

If a future MC server or RCON implementation returns full untruncated entity data, the parser handles it natively — no code changes needed.

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
quoted_string = '"' (escaped_char | [^"\\])* '"' | "'" (escaped_char | [^'\\])* "'"
bare_string = [a-zA-Z0-9._+-]+

number      = float | double | long | short | byte | int
float       = [-]?[0-9]*"."?[0-9]+ ("f" | "F")
double      = [-]?[0-9]*"."[0-9]+ ("d" | "D")?
long        = [-]?[0-9]+ ("l" | "L")
short       = [-]?[0-9]+ ("s" | "S")
byte        = [-]?[0-9]+ ("b" | "B")
int         = [-]?[0-9]+

bool        = "true" | "false"   # sugar for 1/0 (byte)
```

### Type Suffix Summary

| Suffix | Type   | Elixir type | Example      |
|--------|--------|-------------|--------------|
| `b`/`B`| byte   | integer     | `0b`, `127b` |
| `s`/`S`| short  | integer     | `300s`       |
| (none) | int    | integer     | `33`         |
| `l`/`L`| long   | integer     | `1000000L`   |
| `f`/`F`| float  | float       | `20.0f`      |
| `d`/`D`| double | float       | `-412.3d`    |
| (none) | double | float       | `0.5`        |

### Design Decisions

- **Simple representation.** Compounds → maps, lists → lists, all numbers → integer or float. No type wrappers. We read MC data, we don't round-trip it back to SNBT.
- **Truncation is a first-class signal.** Parser returns `{:error, :truncated}` on unexpected EOF. Callers branch on this — no nil-checking heuristics.
- **Single-pass recursive descent.** No tokenizer. Each `parse_*` function takes a binary, returns `{:ok, value, rest}`. ~230 lines total.
- **Booleans desugar.** `true` → `1`, `false` → `0` (matching MC's byte representation).
- **Trailing commas allowed.** `{a: 1, b: 2,}` and `[1, 2, 3,]` are valid (MC emits these).
- **Suffixes case-insensitive.** `0B` == `0b`, `20.0F` == `20.0f`.

### Edge Cases Handled

- Bare keys with dots: `Bukkit.updateLevel`
- Quoted keys with colons: `"minecraft:damage"`
- Nested compounds in lists: `[{Slot: 0b, id: "minecraft:stone"}, ...]`
- Escaped characters in quoted strings: `"say \"hello\""`
- Empty containers: `{}`, `[]`, `[I;]`

## NBT Background

NBT (Named Binary Tag) is Minecraft's native data format — hierarchical, typed, used for everything from player saves to chunk storage. SNBT is its human-readable text form, used in commands and RCON responses.

### Tag Types

| ID   | Tag           | Description                    |
|------|---------------|--------------------------------|
| 0x00 | TAG_End       | Marks end of compound          |
| 0x01 | TAG_Byte      | Signed 8-bit int (`0b`)        |
| 0x02 | TAG_Short     | Signed 16-bit int (`300s`)     |
| 0x03 | TAG_Int       | Signed 32-bit int (`33`)       |
| 0x04 | TAG_Long      | Signed 64-bit int (`1000000L`) |
| 0x05 | TAG_Float     | 32-bit float (`20.0f`)         |
| 0x06 | TAG_Double    | 64-bit float (`-412.3d`)       |
| 0x07 | TAG_Byte_Array| Array of bytes (`[B; 0b, 1b]`) |
| 0x08 | TAG_String    | UTF-8 string                   |
| 0x09 | TAG_List      | Typed list (`[1, 2, 3]`)       |
| 0x0A | TAG_Compound  | Map of named tags (`{...}`)    |
| 0x0B | TAG_Int_Array | Array of ints (`[I; 1, 2]`)    |
| 0x0C | TAG_Long_Array| Array of longs (`[L; 0l, 1l]`) |

### Common MC Data Sources

- `data get entity <player>` — player NBT (health, inventory, position, etc.)
- `data get entity <selector>` — mob/entity NBT
- `data get block <x> <y> <z>` — block entity NBT (chests, signs, etc.)
- `level.dat` — world seed, spawn point, game rules
- `<player>.dat` — player save files

### Future Uses

- **Inventory inspection**: `data get entity @s Inventory` → items with enchantments
- **Block state reading**: `data get block x y z` → chest contents, sign text
- **Mob data**: `data get entity @e[type=zombie,limit=1]` → mob stats
- **ChatBot context**: Give LLM structured inventory/equipment data

### Reference

- [NeoForged NBT docs](https://docs.neoforged.net/docs/datastorage/nbt)
- [Minecraft Wiki: NBT format](https://minecraft.wiki/w/NBT_format)
