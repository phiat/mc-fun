defmodule McFun.SNBT.Parser do
  @moduledoc """
  Single-pass recursive descent parser for Minecraft SNBT (Stringified NBT).

  Each parse function takes a binary and returns `{:ok, value, rest}` where
  `rest` is the unconsumed input, or `{:error, reason}`.

  Not intended to be called directly — use `McFun.SNBT.parse/1` instead.
  """

  @doc "Parse a single SNBT value from the input."
  def parse(input) do
    case skip_ws(input) do
      "" -> {:error, :truncated}
      "{" <> rest -> parse_compound(rest)
      "[" <> rest -> parse_list_or_array(rest)
      "\"" <> _ = s -> parse_quoted_string(s)
      "'" <> _ = s -> parse_quoted_string(s)
      s -> parse_number_or_bare(s)
    end
  end

  # ── Compound: { key: value, ... } ──────────────────────────────────

  defp parse_compound(input) do
    case skip_ws(input) do
      "}" <> rest -> {:ok, %{}, rest}
      "" -> {:error, :truncated}
      s -> parse_compound_pairs(s, %{})
    end
  end

  defp parse_compound_pairs(input, acc) do
    with {:ok, key, rest} <- parse_key(input),
         {:ok, rest} <- expect_colon(skip_ws(rest)),
         {:ok, value, rest} <- parse(rest) do
      acc = Map.put(acc, key, value)

      case skip_ws(rest) do
        "}" <> rest -> {:ok, acc, rest}
        "," <> rest -> parse_compound_after_comma(skip_ws(rest), acc)
        "" -> {:error, :truncated}
        s -> {:error, {:unexpected, String.slice(s, 0, 20)}}
      end
    end
  end

  # Handle trailing comma: "," then "}" is valid
  defp parse_compound_after_comma("}" <> rest, acc), do: {:ok, acc, rest}
  defp parse_compound_after_comma("", _acc), do: {:error, :truncated}
  defp parse_compound_after_comma(input, acc), do: parse_compound_pairs(input, acc)

  defp expect_colon(":" <> rest), do: {:ok, skip_ws(rest)}
  defp expect_colon(""), do: {:error, :truncated}
  defp expect_colon(s), do: {:error, {:expected_colon, String.slice(s, 0, 20)}}

  defp parse_key(input) do
    case input do
      "\"" <> _ -> parse_quoted_string(input)
      "'" <> _ -> parse_quoted_string(input)
      "}" <> _ -> {:error, {:unexpected, "}"}}
      "" -> {:error, :truncated}
      _ -> parse_bare_key(input, <<>>)
    end
  end

  defp parse_bare_key(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?., ?_, ?+, ?-] do
    parse_bare_key(rest, <<acc::binary, c>>)
  end

  defp parse_bare_key(_rest, <<>>), do: {:error, :expected_key}
  defp parse_bare_key(rest, acc), do: {:ok, acc, rest}

  # ── Lists and Typed Arrays: [ ... ] ────────────────────────────────

  defp parse_list_or_array(input) do
    case skip_ws(input) do
      "]" <> rest -> {:ok, [], rest}
      "" -> {:error, :truncated}
      "B;" <> rest -> parse_array_elements(skip_ws(rest), [])
      "I;" <> rest -> parse_array_elements(skip_ws(rest), [])
      "L;" <> rest -> parse_array_elements(skip_ws(rest), [])
      s -> parse_list_elements(s, [])
    end
  end

  defp parse_array_elements(input, acc) do
    case skip_ws(input) do
      "]" <> rest -> {:ok, Enum.reverse(acc), rest}
      "" -> {:error, :truncated}
      s -> parse_sequence_element(s, acc, &parse_array_elements/2)
    end
  end

  defp parse_list_elements(input, acc) do
    parse_sequence_element(input, acc, &parse_list_elements/2)
  end

  defp parse_sequence_element(input, acc, continue) do
    case parse(input) do
      {:ok, value, rest} ->
        acc = [value | acc]

        case skip_ws(rest) do
          "]" <> rest -> {:ok, Enum.reverse(acc), rest}
          "," <> rest -> parse_after_list_comma(skip_ws(rest), acc, continue)
          "" -> {:error, :truncated}
          s -> {:error, {:unexpected, String.slice(s, 0, 20)}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Trailing comma: "," then "]" is valid
  defp parse_after_list_comma("]" <> rest, acc, _continue), do: {:ok, Enum.reverse(acc), rest}
  defp parse_after_list_comma("", _acc, _continue), do: {:error, :truncated}
  defp parse_after_list_comma(input, acc, continue), do: continue.(input, acc)

  # ── Quoted Strings ─────────────────────────────────────────────────

  defp parse_quoted_string(<<q, rest::binary>>) when q in [?", ?'] do
    parse_quoted_chars(rest, q, <<>>)
  end

  defp parse_quoted_chars(<<>>, _q, _acc), do: {:error, :truncated}

  defp parse_quoted_chars(<<q, rest::binary>>, q, acc), do: {:ok, acc, rest}

  defp parse_quoted_chars(<<?\\, c, rest::binary>>, q, acc) do
    parse_quoted_chars(rest, q, <<acc::binary, c>>)
  end

  defp parse_quoted_chars(<<c, rest::binary>>, q, acc) do
    parse_quoted_chars(rest, q, <<acc::binary, c>>)
  end

  # ── Numbers, Booleans, and Bare Strings ────────────────────────────

  defp parse_number_or_bare(input) do
    case input do
      "true" <> rest -> finish_bool_or_bare(1, "true", rest)
      "false" <> rest -> finish_bool_or_bare(0, "false", rest)
      <<c, _::binary>> when c in ?0..?9 or c == ?- -> try_number(input)
      _ -> parse_bare_string(input, <<>>)
    end
  end

  defp finish_bool_or_bare(val, _prefix, <<c, _::binary>> = rest)
       when c in [?,, ?}, ?], ?\s, ?\t, ?\n, ?\r] do
    {:ok, val, rest}
  end

  defp finish_bool_or_bare(val, _prefix, <<>>), do: {:ok, val, <<>>}

  defp finish_bool_or_bare(_val, prefix, rest) do
    parse_bare_string(rest, prefix)
  end

  defp try_number(input) do
    {raw, rest} = consume_numeric(input, <<>>)
    classify_and_return(raw, rest, input)
  end

  defp consume_numeric(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in [?-, ?., ?+, ?e, ?E] do
    consume_numeric(rest, <<acc::binary, c>>)
  end

  # Type suffix: only consume if we have digits before it
  defp consume_numeric(<<c, rest::binary>>, acc)
       when c in [?b, ?B, ?s, ?S, ?l, ?L, ?f, ?F, ?d, ?D] and byte_size(acc) > 0 do
    {<<acc::binary, c>>, rest}
  end

  defp consume_numeric(rest, acc), do: {acc, rest}

  defp classify_and_return(<<>>, _rest, input), do: parse_bare_string(input, <<>>)

  defp classify_and_return(raw, rest, _input) do
    last = :binary.last(raw)
    body = binary_part(raw, 0, byte_size(raw) - 1)

    result =
      cond do
        last in [?f, ?F, ?d, ?D] -> to_float(body)
        last in [?b, ?B, ?s, ?S, ?l, ?L] -> to_int(body)
        has_decimal?(raw) -> to_float(raw)
        true -> to_int(raw)
      end

    case result do
      {:ok, val} -> {:ok, val, rest}
      :error -> parse_bare_string(rest, raw)
    end
  end

  defp has_decimal?(s), do: :binary.match(s, [<<?.>>, <<?e>>, <<?E>>]) != :nomatch

  defp to_float(s) do
    case Float.parse(s) do
      {f, ""} -> {:ok, f}
      {f, "."} -> {:ok, f}
      _ -> :error
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  # ── Bare Strings ───────────────────────────────────────────────────

  @bare_stop [?,, ?:, ?}, ?], ?\s, ?\t, ?\n, ?\r]

  defp parse_bare_string(<<c, rest::binary>>, acc) when c not in @bare_stop do
    parse_bare_string(rest, <<acc::binary, c>>)
  end

  defp parse_bare_string(_rest, <<>>), do: {:error, :expected_value}
  defp parse_bare_string(rest, acc), do: {:ok, acc, rest}

  # ── Whitespace ─────────────────────────────────────────────────────

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(rest), do: rest
end
