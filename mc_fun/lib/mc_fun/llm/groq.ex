defmodule McFun.LLM.Groq do
  @moduledoc """
  Groq API client using Req. Simple chat completion interface.
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
  """
  def chat(system_prompt, messages, opts \\ []) do
    config = Application.get_env(:mc_fun, :groq, [])
    api_key = Keyword.get(config, :api_key, "")
    model = Keyword.get(opts, :model, Keyword.get(config, :model, "llama-3.3-70b-versatile"))
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 512)

    formatted_messages =
      [%{role: "system", content: system_prompt} | format_messages(messages)]

    body = %{
      model: model,
      messages: formatted_messages,
      temperature: temperature,
      max_tokens: max_tokens
    }

    case Req.post(@base_url,
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Groq API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      {role, content} -> %{role: to_string(role), content: content}
      %{} = msg -> msg
    end)
  end
end
