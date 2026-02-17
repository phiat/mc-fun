defmodule McFun.ChatBot.Tools do
  @moduledoc """
  Tool definitions and execution for ChatBot.

  Manages the 20-tool definition list for Groq function calling,
  tool execution dispatch, and model capability detection.
  """

  require Logger

  # Models that support OpenAI-style tool/function calling.
  # Compound models do internal tool calling (websearch etc) and reject external tools.
  @tool_capable_prefixes ~w(llama qwen openai/ meta-llama/ moonshotai/)

  @doc "Returns true if the model supports OpenAI-style tool/function calling."
  def supports_tools?(model_id) do
    Enum.any?(@tool_capable_prefixes, &String.starts_with?(model_id, &1))
  end

  @doc "Returns the list of tool specs for Groq API."
  def definitions do
    [
      tool(
        "goto_player",
        "Move to a player's location",
        %{
          "player" => %{"type" => "string", "description" => "Player name to move to"}
        },
        ["player"]
      ),
      tool(
        "follow_player",
        "Follow a player around continuously",
        %{
          "player" => %{"type" => "string", "description" => "Player name to follow"}
        },
        ["player"]
      ),
      tool("dig", "Dig/mine the block you are looking at", %{}, []),
      tool(
        "find_and_dig",
        "Find the nearest block of a type and mine it",
        %{
          "block_type" => %{
            "type" => "string",
            "description" =>
              "Block type to find and mine, e.g. coal_ore, iron_ore, diamond_ore, oak_log"
          }
        },
        ["block_type"]
      ),
      tool(
        "dig_area",
        "Dig a rectangular area (room/tunnel). Digs from your current position.",
        %{
          "width" => %{"type" => "integer", "description" => "Width (X axis), max 20"},
          "height" => %{
            "type" => "integer",
            "description" => "Height (Y axis), max 10, default 3"
          },
          "depth" => %{"type" => "integer", "description" => "Depth (Z axis), max 20"}
        },
        ["width", "depth"]
      ),
      tool("jump", "Jump once", %{}, []),
      tool("attack", "Attack the nearest entity", %{}, []),
      tool(
        "look",
        "Turn to face a direction. Use yaw: 0=south, 1.57=west, 3.14=north, -1.57=east. Pitch: 0=level, -0.5=up, 0.5=down. Use to turn around before digging.",
        %{
          "yaw" => %{
            "type" => "number",
            "description" =>
              "Horizontal angle in radians. 0=south, 1.57=west, 3.14=north, -1.57=east"
          },
          "pitch" => %{
            "type" => "number",
            "description" => "Vertical angle in radians. 0=level, negative=up, positive=down"
          }
        },
        ["yaw"]
      ),
      tool(
        "drop",
        "Drop/throw the currently held item on the ground. Only use when explicitly asked to drop or throw items.",
        %{},
        []
      ),
      tool(
        "drop_item",
        "Drop a specific item from inventory by name. Optionally specify a count, otherwise drops the entire stack.",
        %{
          "item_name" => %{
            "type" => "string",
            "description" => "Item name (e.g. cobblestone, diamond)"
          },
          "count" => %{
            "type" => "integer",
            "description" => "Number to drop (omit for entire stack)"
          }
        },
        ["item_name"]
      ),
      tool(
        "drop_all",
        "Drop ALL items from inventory onto the ground. Only use when explicitly asked to empty inventory.",
        %{},
        []
      ),
      tool("sneak", "Toggle sneaking/crouching", %{}, []),
      tool(
        "craft",
        "Craft an item",
        %{
          "item" => %{
            "type" => "string",
            "description" => "Item name to craft, e.g. wooden_pickaxe"
          }
        },
        ["item"]
      ),
      tool(
        "equip",
        "Equip an item from inventory",
        %{
          "item" => %{
            "type" => "string",
            "description" => "Item name to equip, e.g. diamond_sword"
          }
        },
        ["item"]
      ),
      tool(
        "activate_block",
        "Interact with a block at coordinates (press button, flip lever, open chest/door)",
        %{
          "x" => %{"type" => "integer", "description" => "X coordinate"},
          "y" => %{"type" => "integer", "description" => "Y coordinate"},
          "z" => %{"type" => "integer", "description" => "Z coordinate"}
        },
        ["x", "y", "z"]
      ),
      tool(
        "use_item",
        "Use the currently held item (eat food, throw, use)",
        %{},
        []
      ),
      tool(
        "sleep",
        "Sleep in a nearby bed (must be within 4 blocks and nighttime)",
        %{},
        []
      ),
      tool(
        "wake",
        "Wake up from a bed",
        %{},
        []
      ),
      tool(
        "stop",
        "Stop the current action (digging, moving, following). Use when asked to stop or cancel.",
        %{},
        []
      )
    ]
  end

  @doc "Execute a tool call by name, dispatching to the appropriate Bot command."
  def execute(bot, "goto_player", %{"player" => player}, _username) do
    McFun.Bot.send_command(bot, %{action: "goto", target: player}, source: :tool)
  end

  def execute(bot, "goto_player", _args, username) do
    McFun.Bot.send_command(bot, %{action: "goto", target: username}, source: :tool)
  end

  def execute(bot, "follow_player", %{"player" => player}, _username) do
    McFun.Bot.send_command(bot, %{action: "follow", target: player}, source: :tool)
  end

  def execute(bot, "follow_player", _args, username) do
    McFun.Bot.send_command(bot, %{action: "follow", target: username}, source: :tool)
  end

  def execute(bot, "dig", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "dig_looking_at"}, source: :tool)
  end

  def execute(bot, "find_and_dig", %{"block_type" => block_type}, _username) do
    McFun.Bot.send_command(bot, %{action: "find_and_dig", block_type: block_type}, source: :tool)
  end

  def execute(bot, "dig_area", args, _username) do
    McFun.Bot.dig_area(bot, args, source: :tool)
  end

  def execute(bot, "jump", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "jump"}, source: :tool)
  end

  def execute(bot, "attack", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "attack"}, source: :tool)
  end

  def execute(bot, "look", args, _username) do
    yaw = args["yaw"] || 0
    pitch = args["pitch"] || 0
    McFun.Bot.send_command(bot, %{action: "look", yaw: yaw, pitch: pitch}, source: :tool)
  end

  def execute(bot, "drop", _args, _username) do
    McFun.Bot.drop(bot)
  end

  def execute(bot, "drop_item", args, _username) do
    item_name = args["item_name"]
    count = args["count"]
    McFun.Bot.drop_item(bot, item_name, count)
  end

  def execute(bot, "drop_all", _args, _username) do
    McFun.Bot.drop_all(bot)
  end

  def execute(bot, "sneak", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "sneak"}, source: :tool)
  end

  def execute(bot, "craft", %{"item" => item}, _username) do
    McFun.Bot.craft(bot, item)
  end

  def execute(bot, "equip", %{"item" => item}, _username) do
    McFun.Bot.equip(bot, item)
  end

  def execute(bot, "activate_block", %{"x" => x, "y" => y, "z" => z}, _username) do
    McFun.Bot.send_command(bot, %{action: "activate_block", x: x, y: y, z: z}, source: :tool)
  end

  def execute(bot, "use_item", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "use_item"}, source: :tool)
  end

  def execute(bot, "sleep", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "sleep"}, source: :tool)
  end

  def execute(bot, "wake", _args, _username) do
    McFun.Bot.send_command(bot, %{action: "wake"}, source: :tool)
  end

  def execute(bot, "stop", _args, _username) do
    McFun.Bot.stop_action(bot)
  end

  def execute(_bot, name, args, _username) do
    Logger.warning("ChatBot: unknown tool call #{name}(#{inspect(args)})")
  end

  @doc "Returns action instruction text for the system prompt based on tool support."
  def action_instructions(true = _use_tools) do
    """
    You control a real bot. When a player asks you to do something physical, use the appropriate tool. IMPORTANT: You MUST always include a text response in addition to any tool calls — never return only a tool call with no message. Available tools: goto_player, follow_player, dig, find_and_dig, dig_area (width/height/depth for rooms/tunnels), look (turn to face a direction — use before digging in a new direction), jump, attack, drop (ONLY when asked to drop items), sneak, craft, equip, activate_block (buttons/levers/chests/doors at x,y,z), use_item (eat/use held item), sleep (nearby bed), wake, stop. Use 'stop' when the player asks you to stop or cancel. Use 'look' to turn around (yaw=3.14 for 180° turn) before digging in a new direction. NEVER use 'drop' unless the player explicitly asks to drop or throw items.

    CRITICAL: Your response MUST start with "REPLY:" followed by your chat message. Do NOT include any thinking, reasoning, or analysis. Only output what the player should see.
    Example: REPLY: Sure thing, I'll dig that for you!
    """
  end

  def action_instructions(false) do
    """
    You control a real bot. To perform actions, you MUST include the exact trigger phrase in your response. One action per response.

    TRIGGER PHRASES (use exactly):
    "on my way" or "coming to you" → move to the player
    "I'll follow" or "following you" → follow the player
    "I'll dig" or "mining" → dig the block you're looking at
    "I'll jump" → jump
    "I'll attack" or "attacking" → attack nearest entity
    "I'll drop" or "dropping" → drop held item
    "sneaking" → sneak/crouch
    "I'll craft [item]" → craft an item
    "I'll equip [item]" → equip an item

    If a player asks you to do something physical, ALWAYS include the trigger phrase.

    CRITICAL: Your response MUST start with "REPLY:" followed by your chat message. Do NOT include any thinking, reasoning, or analysis. Only output what the player should see.
    Example: REPLY: On my way, I'll dig that block!
    """
  end

  # Private helpers

  defp tool(name, description, properties, required) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: properties,
          required: required
        }
      }
    }
  end
end
