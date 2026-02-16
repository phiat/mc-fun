defmodule McFun.CostTracker do
  @moduledoc """
  Tracks LLM token usage and estimated cost per bot and globally.

  Listens for `{:cost_event, bot_name, metrics}` on the "costs" PubSub topic,
  computes cost from Groq pricing, and stores in ETS with periodic JSON disk persistence.
  Broadcasts `{:cost_updated, summary}` after each recording.
  """
  use GenServer
  require Logger

  @table :mc_fun_costs
  @persistence_path "apps/mc_fun/priv/cost_data.json"
  @flush_delay_ms 5_000

  # Groq model pricing ($/1M tokens)
  @pricing %{
    "openai/gpt-oss-20b" => %{input: 0.10, output: 0.30},
    "openai/gpt-oss-120b" => %{input: 0.30, output: 1.20},
    "llama-3.3-70b-versatile" => %{input: 0.59, output: 0.79},
    "llama-3.1-8b-instant" => %{input: 0.05, output: 0.08},
    "qwen/qwen3-32b" => %{input: 0.20, output: 0.50},
    "meta-llama/llama-4-maverick-17b-128e-instruct" => %{input: 0.50, output: 0.77},
    "meta-llama/llama-4-scout-17b-16e-instruct" => %{input: 0.11, output: 0.34},
    "groq/compound-mini" => %{input: 0.04, output: 0.04},
    "groq/compound" => %{input: 0.04, output: 0.04},
    "moonshotai/kimi-k2-instruct" => %{input: 0.40, output: 1.20}
  }
  @default_pricing %{input: 0.10, output: 0.30}

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get cost summary for a specific bot."
  def get_bot_cost(bot_name) do
    case :ets.lookup(@table, {:bot, bot_name}) do
      [{_, data}] -> data
      [] -> %{cost: 0.0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, calls: 0}
    end
  end

  @doc "Get global cost summary across all bots."
  def get_global_cost do
    case :ets.lookup(@table, :global) do
      [{_, data}] -> data
      [] -> %{cost: 0.0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, calls: 0}
    end
  end

  @doc "Record a cost event manually (mainly for testing)."
  def record(bot_name, metrics) do
    GenServer.cast(__MODULE__, {:record, bot_name, metrics})
  end

  @doc "Reset all cost tracking data."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Format a cost value for display."
  def format_cost(cost) when cost < 0.01, do: "$#{Float.round(cost * 1.0, 4)}"
  def format_cost(cost), do: "$#{Float.round(cost * 1.0, 2)}"

  @doc "Format a token count for display."
  def format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  def format_tokens(n) when is_integer(n), do: "#{n}"
  def format_tokens(_), do: "0"

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_from_disk()
    Phoenix.PubSub.subscribe(McFun.PubSub, "costs")
    {:ok, %{table: table, flush_ref: nil}}
  end

  @impl true
  def handle_cast({:record, bot_name, metrics}, state) do
    do_record(bot_name, metrics)
    state = schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:cost_event, bot_name, metrics}, state) do
    do_record(bot_name, metrics)
    state = schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_to_disk, state) do
    save_to_disk()
    {:noreply, %{state | flush_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    save_to_disk()
    broadcast_update()
    {:reply, :ok, state}
  end

  # Internal

  defp do_record(bot_name, metrics) do
    model = Map.get(metrics, :model, "unknown")
    prompt_tokens = Map.get(metrics, :prompt_tokens, 0)
    completion_tokens = Map.get(metrics, :completion_tokens, 0)
    total_tokens = Map.get(metrics, :total_tokens, 0)

    pricing = Map.get(@pricing, model, @default_pricing)

    cost =
      prompt_tokens / 1_000_000 * pricing.input + completion_tokens / 1_000_000 * pricing.output

    # Update per-bot
    update_entry({:bot, bot_name}, prompt_tokens, completion_tokens, total_tokens, cost)

    # Update global
    update_entry(:global, prompt_tokens, completion_tokens, total_tokens, cost)

    broadcast_update()
  end

  defp update_entry(key, prompt_tokens, completion_tokens, total_tokens, cost) do
    existing =
      case :ets.lookup(@table, key) do
        [{_, data}] -> data
        [] -> %{cost: 0.0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, calls: 0}
      end

    updated = %{
      cost: existing.cost + cost,
      prompt_tokens: existing.prompt_tokens + prompt_tokens,
      completion_tokens: existing.completion_tokens + completion_tokens,
      total_tokens: existing.total_tokens + total_tokens,
      calls: existing.calls + 1
    }

    :ets.insert(@table, {key, updated})
  end

  defp broadcast_update do
    summary = get_global_cost()
    Phoenix.PubSub.broadcast(McFun.PubSub, "costs", {:cost_updated, summary})
  end

  defp schedule_flush(state) do
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    ref = Process.send_after(self(), :flush_to_disk, @flush_delay_ms)
    %{state | flush_ref: ref}
  end

  defp save_to_disk do
    data =
      :ets.tab2list(@table)
      |> Enum.map(fn {key, value} ->
        string_key =
          case key do
            {:bot, name} -> "bot:#{name}"
            :global -> "global"
          end

        {string_key, value}
      end)
      |> Map.new()

    path = Path.join(File.cwd!(), @persistence_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    error ->
      Logger.warning("CostTracker: failed to save to disk: #{inspect(error)}")
  end

  defp load_from_disk do
    path = Path.join(File.cwd!(), @persistence_path)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      data
      |> Enum.map(fn {key, value} -> {parse_storage_key(key), value} end)
      |> Enum.reject(fn {key, _} -> is_nil(key) end)
      |> Enum.each(fn {key, value} ->
        :ets.insert(@table, {key, parse_entry(value)})
      end)

      Logger.info("CostTracker: loaded #{map_size(data)} entries from disk")
    else
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("CostTracker: failed to load cost data: #{inspect(reason)}")
    end
  end

  defp parse_storage_key("bot:" <> name), do: {:bot, name}
  defp parse_storage_key("global"), do: :global
  defp parse_storage_key(_), do: nil

  defp parse_entry(value) do
    %{
      cost: value["cost"] || 0.0,
      prompt_tokens: value["prompt_tokens"] || 0,
      completion_tokens: value["completion_tokens"] || 0,
      total_tokens: value["total_tokens"] || 0,
      calls: value["calls"] || 0
    }
  end
end
