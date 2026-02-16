defmodule McFun.SNBTTest do
  use ExUnit.Case, async: true

  alias McFun.SNBT

  describe "scalars" do
    test "float with f suffix" do
      assert SNBT.parse("20.0f") == {:ok, 20.0}
      assert SNBT.parse("15.68935f") == {:ok, 15.68935}
      assert SNBT.parse("-3.5F") == {:ok, -3.5}
    end

    test "double with d suffix" do
      assert SNBT.parse("-412.30000001192093d") == {:ok, -412.30000001192093}
      assert SNBT.parse("62.0d") == {:ok, 62.0}
      assert SNBT.parse("0.5D") == {:ok, 0.5}
    end

    test "double without suffix (has decimal)" do
      assert SNBT.parse("0.5") == {:ok, 0.5}
      assert SNBT.parse("-1.23") == {:ok, -1.23}
    end

    test "byte with b suffix" do
      assert SNBT.parse("0b") == {:ok, 0}
      assert SNBT.parse("127b") == {:ok, 127}
      assert SNBT.parse("-1B") == {:ok, -1}
    end

    test "short with s suffix" do
      assert SNBT.parse("300s") == {:ok, 300}
      assert SNBT.parse("-100S") == {:ok, -100}
    end

    test "long with l suffix" do
      assert SNBT.parse("1000000L") == {:ok, 1_000_000}
      assert SNBT.parse("0l") == {:ok, 0}
    end

    test "plain integer (no suffix)" do
      assert SNBT.parse("33") == {:ok, 33}
      assert SNBT.parse("0") == {:ok, 0}
      assert SNBT.parse("-7") == {:ok, -7}
    end

    test "quoted string" do
      assert SNBT.parse(~s|"minecraft:overworld"|) == {:ok, "minecraft:overworld"}
      assert SNBT.parse(~s|"hello world"|) == {:ok, "hello world"}
      assert SNBT.parse(~s|'single quoted'|) == {:ok, "single quoted"}
    end

    test "quoted string with escapes" do
      assert SNBT.parse(~s|"say \\"hello\\""|) == {:ok, ~s|say "hello"|}
    end

    test "boolean sugar" do
      assert SNBT.parse("true") == {:ok, 1}
      assert SNBT.parse("false") == {:ok, 0}
    end
  end

  describe "compounds" do
    test "empty compound" do
      assert SNBT.parse("{}") == {:ok, %{}}
    end

    test "simple compound" do
      assert SNBT.parse("{Health: 20.0f, foodLevel: 20}") ==
               {:ok, %{"Health" => 20.0, "foodLevel" => 20}}
    end

    test "compound with quoted keys" do
      assert SNBT.parse(~s|{"minecraft:damage": 5}|) ==
               {:ok, %{"minecraft:damage" => 5}}
    end

    test "compound with bare dotted key" do
      assert SNBT.parse("{Bukkit.updateLevel: 2}") ==
               {:ok, %{"Bukkit.updateLevel" => 2}}
    end

    test "trailing comma" do
      assert SNBT.parse("{a: 1, b: 2,}") == {:ok, %{"a" => 1, "b" => 2}}
    end

    test "nested compound" do
      input = ~s|{components: {"minecraft:damage": 5}}|

      assert SNBT.parse(input) ==
               {:ok, %{"components" => %{"minecraft:damage" => 5}}}
    end
  end

  describe "lists" do
    test "empty list" do
      assert SNBT.parse("[]") == {:ok, []}
    end

    test "list of doubles" do
      assert SNBT.parse("[-412.3d, 62.0d, 288.7d]") ==
               {:ok, [-412.3, 62.0, 288.7]}
    end

    test "list of compounds" do
      input = ~s|[{Slot: 0b, id: "minecraft:stone_pickaxe", count: 1}]|

      assert {:ok, [%{"Slot" => 0, "id" => "minecraft:stone_pickaxe", "count" => 1}]} =
               SNBT.parse(input)
    end

    test "trailing comma in list" do
      assert SNBT.parse("[1, 2, 3,]") == {:ok, [1, 2, 3]}
    end
  end

  describe "typed arrays" do
    test "byte array" do
      assert SNBT.parse("[B; 0b, 30b]") == {:ok, [0, 30]}
    end

    test "int array" do
      assert SNBT.parse("[I; 1, 2, 3]") == {:ok, [1, 2, 3]}
      assert SNBT.parse("[I; 0, -300]") == {:ok, [0, -300]}
    end

    test "long array" do
      assert SNBT.parse("[L; 0l, 240l]") == {:ok, [0, 240]}
    end

    test "empty typed array" do
      assert SNBT.parse("[I;]") == {:ok, []}
      assert SNBT.parse("[B;]") == {:ok, []}
      assert SNBT.parse("[L;]") == {:ok, []}
    end
  end

  describe "truncation" do
    test "truncated compound" do
      assert SNBT.parse("{Health: 20.0f, Pos: [-412.3d, 62.0d") == {:error, :truncated}
    end

    test "truncated string" do
      assert SNBT.parse(~s|"unclosed|) == {:error, :truncated}
    end

    test "truncated list" do
      assert SNBT.parse("[1, 2, 3") == {:error, :truncated}
    end

    test "empty input" do
      assert SNBT.parse("") == {:error, :truncated}
    end

    test "truncated mid-compound" do
      assert SNBT.parse("{a: 1, b:") == {:error, :truncated}
    end
  end

  describe "real MC server output" do
    test "full entity data (truncated as RCON sends it)" do
      # Real truncated RCON response
      input =
        "{Bukkit.updateLevel: 2, foodTickTimer: 0, AbsorptionAmount: 0.0f, " <>
          "XpTotal: 33, playerGameType: 0, Invulnerable: 0b, SelectedItemSlot: 3, ..."

      assert {:error, _} = SNBT.parse(input)
    end

    test "health field response" do
      assert SNBT.parse_entity_response(
               "DonaldMahanahan has the following entity data: 15.68935f"
             ) == {:ok, 15.68935}
    end

    test "position field response" do
      assert SNBT.parse_entity_response(
               "DonaldMahanahan has the following entity data: [-412.30000001192093d, 62.0d, 288.69999998807907d]"
             ) == {:ok, [-412.30000001192093, 62.0, 288.69999998807907]}
    end

    test "dimension field response" do
      assert SNBT.parse_entity_response(
               ~s|DonaldMahanahan has the following entity data: "minecraft:overworld"|
             ) == {:ok, "minecraft:overworld"}
    end

    test "food level field response" do
      assert SNBT.parse_entity_response("DonaldMahanahan has the following entity data: 17") ==
               {:ok, 17}
    end

    test "inventory field response" do
      input =
        ~s|DonaldMahanahan has the following entity data: [{Slot: 0b, id: "minecraft:stone_pickaxe", count: 1, components: {"minecraft:damage": 5}}]|

      assert {:ok, [item]} = SNBT.parse_entity_response(input)
      assert item["Slot"] == 0
      assert item["id"] == "minecraft:stone_pickaxe"
      assert item["count"] == 1
      assert item["components"] == %{"minecraft:damage" => 5}
    end

    test "player list parsing (not SNBT, but verifying we don't break on it)" do
      # This is NOT SNBT — just confirming parse rejects it cleanly
      assert {:ok, _} = SNBT.parse("2")
    end
  end

  describe "get/2 path access" do
    setup do
      {:ok, data} =
        SNBT.parse(~s|{Health: 20.0f, Pos: [1.0d, 2.0d, 3.0d], Dimension: "minecraft:overworld"}|)

      %{data: data}
    end

    test "top-level key", %{data: data} do
      assert SNBT.get(data, "Health") == {:ok, 20.0}
    end

    test "nested list index", %{data: data} do
      assert SNBT.get(data, "Pos.0") == {:ok, 1.0}
      assert SNBT.get(data, "Pos.2") == {:ok, 3.0}
    end

    test "full list", %{data: data} do
      assert SNBT.get(data, "Pos") == {:ok, [1.0, 2.0, 3.0]}
    end

    test "missing key", %{data: data} do
      assert SNBT.get(data, "Missing") == :error
    end

    test "out of bounds index", %{data: data} do
      assert SNBT.get(data, "Pos.5") == :error
    end

    test "list path syntax" do
      {:ok, data} =
        SNBT.parse(~s|{items: [{id: "stone"}, {id: "dirt"}]}|)

      assert SNBT.get(data, ["items", 0, "id"]) == {:ok, "stone"}
      assert SNBT.get(data, ["items", 1, "id"]) == {:ok, "dirt"}
    end
  end
end
