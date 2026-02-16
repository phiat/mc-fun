defmodule McFun.SNBT do
  @moduledoc """
  Parse Minecraft SNBT (Stringified NBT) into Elixir terms.

  Compounds become maps, lists become lists, typed arrays become lists,
  and all numbers become integers or floats (type suffixes are stripped).

  ## Examples

      iex> McFun.SNBT.parse("{Health: 20.0f, foodLevel: 20}")
      {:ok, %{"Health" => 20.0, "foodLevel" => 20}}

      iex> McFun.SNBT.parse("15.68935f")
      {:ok, 15.68935}

      iex> McFun.SNBT.parse("{Health: 20.0f, Pos: [-412.3d")
      {:error, :truncated}
  """

  alias McFun.SNBT.Parser

  @entity_prefix ~r/^\S+ has the following entity data: /

  @doc "Parse an SNBT string into an Elixir term."
  @spec parse(String.t()) :: {:ok, term()} | {:error, term()}
  def parse(input) when is_binary(input) do
    case Parser.parse(input) do
      {:ok, value, _rest} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  @doc """
  Parse an RCON `data get entity` response, stripping the player prefix.

  Handles responses like:
    "Steve has the following entity data: {Health: 20.0f, ...}"
    "Steve has the following entity data: 20.0f"
  """
  @spec parse_entity_response(String.t()) :: {:ok, term()} | {:error, term()}
  def parse_entity_response(response) when is_binary(response) do
    response
    |> String.replace(@entity_prefix, "", global: false)
    |> parse()
  end

  @doc """
  Get a value at a path from a parsed SNBT map.

  Path can be a dot-separated string or a list of keys/indices.

      iex> {:ok, data} = McFun.SNBT.parse(~s|{Pos: [1.0d, 2.0d, 3.0d]}|)
      iex> McFun.SNBT.get(data, "Pos")
      {:ok, [1.0, 2.0, 3.0]}

      iex> McFun.SNBT.get(data, "Pos.0")
      {:ok, 1.0}

      iex> McFun.SNBT.get(data, "Missing")
      :error
  """
  @spec get(term(), String.t() | [String.t() | integer()]) :: {:ok, term()} | :error
  def get(data, path) when is_binary(path) do
    segments =
      path
      |> String.split(".")
      |> Enum.map(fn seg ->
        case Integer.parse(seg) do
          {i, ""} -> i
          _ -> seg
        end
      end)

    get(data, segments)
  end

  def get(data, []), do: {:ok, data}

  def get(data, [key | rest]) when is_map(data) and is_binary(key) do
    case Map.fetch(data, key) do
      {:ok, val} -> get(val, rest)
      :error -> :error
    end
  end

  def get(data, [idx | rest]) when is_list(data) and is_integer(idx) do
    if idx >= 0 and idx < length(data) do
      get(Enum.at(data, idx), rest)
    else
      :error
    end
  end

  def get(_data, _path), do: :error
end
