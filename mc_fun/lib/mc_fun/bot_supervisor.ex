defmodule McFun.BotSupervisor do
  @moduledoc """
  Functions for managing mineflayer bots via the DynamicSupervisor.
  """

  @doc "Spawn a new bot with the given name."
  def spawn_bot(name, opts \\ []) do
    opts = Keyword.put(opts, :name, name)

    DynamicSupervisor.start_child(
      __MODULE__,
      {McFun.Bot, opts}
    )
  end

  @doc "Stop a running bot."
  def stop_bot(name) do
    case Registry.lookup(McFun.BotRegistry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "List all running bot names."
  def list_bots do
    Registry.select(McFun.BotRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {name, _pid} -> is_binary(name) end)
    |> Enum.map(fn {name, _pid} -> name end)
  end
end
