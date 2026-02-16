defmodule McFun.Rcon do
  @moduledoc """
  Stateless routing facade for RCON connections.

  Routes interactive commands to a dedicated `:command` connection and
  background polling to a round-robin pool of `{:poll, N}` connections.

  All existing `McFun.Rcon.command/1` callers are unchanged — they hit
  the dedicated command lane automatically.

  ## New API

  - `poll_command/2` — routes to the poll pool (for LogWatcher, etc.)
  - `pool_size/0` — returns the number of poll connections
  """

  @doc "Send an RCON command on the dedicated interactive lane."
  def command(cmd, timeout \\ 5_000) do
    GenServer.call(via(:command), {:command, cmd}, timeout)
  end

  @doc "Send an RCON command on the poll pool (round-robin)."
  def poll_command(cmd, timeout \\ 5_000) do
    GenServer.call(via(next_poll_key()), {:command, cmd}, timeout)
  end

  @doc "Check if the command connection is healthy."
  def healthy? do
    GenServer.call(via(:command), :healthy?, 2_000)
  catch
    :exit, _ -> false
  end

  @doc "Number of poll connections in the pool."
  def pool_size do
    :persistent_term.get(:rcon_pool_size, 2)
  end

  # Internal

  defp via(key) do
    {:via, Registry, {McFun.Rcon.Registry, key}}
  end

  defp next_poll_key do
    counter = :persistent_term.get(:rcon_poll_counter)
    index = :atomics.add_get(counter, 1, 1)
    size = pool_size()
    {:poll, rem(index - 1, size) + 1}
  end
end
