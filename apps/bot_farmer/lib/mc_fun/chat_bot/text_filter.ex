defmodule McFun.ChatBot.TextFilter do
  @moduledoc """
  Text processing utilities for ChatBot responses.

  Handles chain-of-thought stripping, text chunking for Minecraft chat,
  and paginated message sending.
  """

  require Logger

  @chat_line_length 180
  @max_chat_lines 4

  @cot_start_pattern ~r/^(The |We |User|They |I need|Let me|So |OK |Alright|Hmm|First|Now|My |This |Here|Since )/i

  @doc """
  Strip chain-of-thought from reasoning models.

  Expects "REPLY: actual message" format; falls back to extracting the actual reply
  from various CoT patterns.
  """
  def strip_thinking(text) do
    trimmed = String.trim(text)

    cond do
      # Explicit REPLY: marker — most reliable
      String.contains?(text, "REPLY:") ->
        text
        |> String.split("REPLY:")
        |> List.last()
        |> String.trim()

      # Looks like thinking (starts with analysis/reasoning)
      Regex.match?(@cot_start_pattern, trimmed) ->
        extract_reply_from_cot(trimmed)

      true ->
        text
    end
  end

  @doc """
  Send text as paginated chat messages, chunked at word boundaries.

  Modes:
    * `:chat` — public chat (default)
    * `:whisper` — whisper to target player
  """
  def send_paginated(bot_name, text, mode \\ :chat, target \\ nil) do
    text
    |> chunk_text(@chat_line_length)
    |> Enum.take(@max_chat_lines)
    |> Enum.each(fn line ->
      case mode do
        :whisper when is_binary(target) -> McFun.Bot.whisper(bot_name, target, line)
        _ -> McFun.Bot.chat(bot_name, line)
      end

      Process.sleep(300)
    end)
  end

  @doc "Split text into chunks at word boundaries, each at most `max_len` characters."
  def chunk_text(text, max_len) do
    words = String.split(text)
    chunk_words(words, max_len, "", [])
  end

  # Private helpers

  # Try multiple strategies to extract the actual reply from chain-of-thought text
  defp extract_reply_from_cot(text) do
    # Strategy 1: Find complete quoted text (with closing quote)
    case Regex.run(~r/["""]([^"""]+)["""]/, text) do
      [_, quoted] when byte_size(quoted) > 10 ->
        String.trim(quoted)

      _ ->
        # Strategy 2: Find text after "like:" or "say:" or "response:" markers
        case Regex.run(~r/(?:like|say|response|reply|answer|here|goes):\s*["""]?(.+)/is, text) do
          [_, after_marker] ->
            after_marker
            |> String.replace(~r/^["""]|["""]$/, "")
            |> String.trim()

          nil ->
            # Strategy 3: Take the last sentence/paragraph (skip the reasoning)
            parts =
              text
              |> String.split(~r/\n\n+/)
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            last_part = List.last(parts) || text

            # If the last part still looks like reasoning, return empty
            # to avoid leaking CoT into chat
            if Regex.match?(@cot_start_pattern, last_part) and length(parts) > 1 do
              Logger.warning("ChatBot: strip_thinking failed to extract reply, suppressing CoT")
              ""
            else
              last_part
            end
        end
    end
  end

  defp chunk_words([], _max, "", acc), do: Enum.reverse(acc)
  defp chunk_words([], _max, current, acc), do: Enum.reverse([current | acc])

  defp chunk_words([word | rest], max, current, acc) do
    candidate =
      if current == "", do: word, else: current <> " " <> word

    if String.length(candidate) <= max do
      chunk_words(rest, max, candidate, acc)
    else
      if current == "" do
        # Single word longer than max — force it in
        chunk_words(rest, max, "", [word | acc])
      else
        chunk_words([word | rest], max, "", [current | acc])
      end
    end
  end
end
