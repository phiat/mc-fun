defmodule McFun.LLM.Groq do
  @moduledoc """
  Groq API client using Req. Supports chat completions with tool/function calling.
  """
  require Logger

  @base_url "https://api.groq.com/openai/v1/chat/completions"

  @doc """
  Send a chat completion request.
  Returns `{:ok, response_text}` or `{:error, reason}`.

  Options:
    - :model - model name (default from config)
    - :temperature - 0.0-2.0 (default 0.7)
    - :max_tokens - max response tokens (default 512)
    - :tools - list of tool definitions (OpenAI format)
  """
  def chat(system_prompt, messages, opts \\ []) do
    config = Application.get_env(:mc_fun, :groq, [])
    api_key = Keyword.get(config, :api_key, "")
    model = Keyword.get(opts, :model, Keyword.get(config, :model, "llama-3.3-70b-versatile"))
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 512)
    tools = Keyword.get(opts, :tools, nil)

    formatted_messages =
      [%{role: "system", content: system_prompt} | format_messages(messages)]

    body =
      %{
        model: model,
        messages: formatted_messages,
        temperature: temperature,
        max_tokens: max_tokens
      }
      |> maybe_add_tools(tools)

    case Req.post(@base_url,
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => message} | _]}}} ->
        parse_response(message)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Groq API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp parse_response(%{"content" => content, "tool_calls" => tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    parsed_calls =
      Enum.map(tool_calls, fn
        %{"function" => %{"name" => name, "arguments" => args_json}} ->
          case Jason.decode(args_json) do
            {:ok, args} -> %{name: name, args: args}
            _ -> %{name: name, args: %{}}
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, content || "", parsed_calls}
  end

  defp parse_response(%{"content" => content}) do
    {:ok, content || ""}
  end

  defp parse_response(other) do
    Logger.warning("Groq: unexpected message format: #{inspect(other)}")
    {:error, :unexpected_format}
  end

  defp format_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      {role, content} -> %{role: to_string(role), content: content}
      %{} = msg -> msg
    end)
  end
end
