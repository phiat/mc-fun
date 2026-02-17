defmodule McFun.BotJobQueue do
  @moduledoc """
  Per-bot job queue for sequential action execution.

  Spawned on demand, registered as `{:job_queue, bot_name}` in BotRegistry.
  Subscribes to bot PubSub for completion events to auto-advance the queue.

  ## Usage

      BotFarmer.enqueue_jobs("Bot", [
        {:goto, %{x: 0, y: 64, z: 0}},
        {:find_and_dig, %{block_type: "diamond_ore"}},
        {:goto, %{x: 100, y: 64, z: 100}}
      ])
  """
  use GenServer, restart: :temporary
  require Logger

  @completion_events ~w(goto_done dig_done find_and_dig_done dig_area_done stopped)

  defstruct [:bot_name, queue: :queue.new(), current_job: nil, completed: 0]

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Enqueue a list of jobs for a bot. Starts the queue GenServer if needed."
  def enqueue(bot_name, jobs) when is_list(jobs) do
    ensure_started(bot_name)
    GenServer.call(via(bot_name), {:enqueue, jobs})
  end

  @doc "Get queue status for a bot. Returns nil if no queue exists."
  def status(bot_name) do
    GenServer.call(via(bot_name), :status)
  catch
    :exit, _ -> nil
  end

  @doc "Clear all pending jobs for a bot."
  def clear(bot_name) do
    GenServer.call(via(bot_name), :clear)
  catch
    :exit, _ -> :ok
  end

  # ── Startup ─────────────────────────────────────────────────────────

  def start_link(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    GenServer.start_link(__MODULE__, bot_name, name: via(bot_name))
  end

  defp via(name), do: {:via, Registry, {McFun.BotRegistry, {:job_queue, name}}}

  defp ensure_started(bot_name) do
    case Registry.lookup(McFun.BotRegistry, {:job_queue, bot_name}) do
      [{_pid, _}] ->
        :ok

      [] ->
        spec = {__MODULE__, bot_name: bot_name}

        case DynamicSupervisor.start_child(McFun.BotSupervisor, spec) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          error -> error
        end
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(bot_name) do
    Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot_name}")
    {:ok, %__MODULE__{bot_name: bot_name}}
  end

  @impl true
  def handle_call({:enqueue, jobs}, _from, state) do
    queue =
      Enum.reduce(jobs, state.queue, fn job, q ->
        :queue.in(job, q)
      end)

    new_state = %{state | queue: queue}

    # If nothing currently running, start the first job
    new_state = if is_nil(state.current_job), do: pop_and_execute(new_state), else: new_state
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       current: state.current_job,
       queued: :queue.len(state.queue),
       completed: state.completed
     }, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | queue: :queue.new()}}
  end

  @impl true
  def handle_info({:bot_event, _bot, %{"event" => event}}, state)
      when event in @completion_events do
    if state.current_job do
      Logger.info("BotJobQueue #{state.bot_name}: job completed (#{event}), advancing queue")
      new_state = %{state | current_job: nil, completed: state.completed + 1}
      {:noreply, pop_and_execute(new_state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ────────────────────────────────────────────────────────

  defp pop_and_execute(state) do
    case :queue.out(state.queue) do
      {{:value, {action, params}}, rest} ->
        Logger.info("BotJobQueue #{state.bot_name}: executing #{action}")
        command = Map.put(params, :action, to_string(action))
        McFun.Bot.send_command(state.bot_name, command, source: :tool)
        %{state | queue: rest, current_job: {action, params}}

      {:empty, _} ->
        Logger.info("BotJobQueue #{state.bot_name}: queue empty")
        state
    end
  end
end
