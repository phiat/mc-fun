defmodule McFun.LLM.ModelCache do
  @moduledoc """
  Fetches and caches available Groq models. Stores to priv/groq_models.json
  and keeps an in-memory ETS cache.

  ## Usage

      McFun.LLM.ModelCache.list_models()
      McFun.LLM.ModelCache.refresh()
      McFun.LLM.ModelCache.get_model("llama-3.3-70b-versatile")
  """
  use GenServer
  require Logger

  @table :groq_models
  @cache_file "groq_models.json"
  @refresh_interval :timer.hours(6)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all cached model IDs."
  @spec list_models() :: [map()]
  def list_models do
    case :ets.lookup(@table, :models) do
      [{:models, models}] -> models
      [] -> []
    end
  end

  @doc "Get a specific model by ID."
  @spec get_model(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_model(model_id) do
    case Enum.find(list_models(), &(&1["id"] == model_id)) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @doc "List just the model ID strings (chat-capable models only)."
  @spec model_ids() :: [String.t()]
  def model_ids do
    list_models()
    |> Enum.filter(&chat_capable?/1)
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  # Filter out non-chat models: audio (whisper), safety (guard/safeguard), TTS (orpheus)
  defp chat_capable?(%{"context_window" => ctx, "max_completion_tokens" => max_tok})
       when ctx >= 8192 and max_tok >= 2048,
       do: true

  defp chat_capable?(_), do: false

  @doc "Force refresh from the Groq API."
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    GenServer.call(__MODULE__, :refresh, 15_000)
  end

  # GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    # Load from disk cache first
    load_from_file()

    # Then try to refresh from API in background
    Process.send_after(self(), :refresh, 1_000)

    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    result = fetch_and_cache()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    fetch_and_cache()
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp fetch_and_cache do
    config = Application.get_env(:mc_fun, :groq, [])
    api_key = Keyword.get(config, :api_key, "")

    if api_key == "" or String.starts_with?(api_key, "your_") do
      Logger.warning("ModelCache: no valid Groq API key configured, skipping refresh")
      {:error, :no_api_key}
    else
      case Req.get("https://api.groq.com/openai/v1/models",
             headers: [{"authorization", "Bearer #{api_key}"}],
             receive_timeout: 10_000,
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          store_models(models)
          save_to_file(models)
          Logger.info("ModelCache: cached #{length(models)} models from Groq API")
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("ModelCache: Groq API returned #{status}")
          {:error, {:api_error, status}}

        {:error, reason} ->
          Logger.warning("ModelCache: fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp store_models(models) do
    :ets.insert(@table, {:models, models})
  end

  defp cache_path do
    Path.join(:code.priv_dir(:mc_fun), @cache_file)
  end

  defp save_to_file(models) do
    path = cache_path()

    case Jason.encode(models, pretty: true) do
      {:ok, json} -> File.write(path, json)
      _ -> :ok
    end
  end

  defp load_from_file do
    path = cache_path()

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, models} when is_list(models) ->
            store_models(models)
            Logger.info("ModelCache: loaded #{length(models)} models from disk cache")

          _ ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end
end
