defmodule McFun.Rcon.Supervisor do
  @moduledoc """
  Supervises the RCON connection pool.

  Starts a dedicated `:command` connection for interactive use and
  N `{:poll, i}` connections for background polling (LogWatcher, etc).

  ## Config

      config :mc_fun, :rcon,
        host: "localhost",
        port: 25575,
        password: "secret",
        pool_size: 2
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:mc_fun, :rcon, [])
    pool_size = Keyword.get(config, :pool_size, 2)

    # Store pool size in persistent_term for the facade
    :persistent_term.put(:rcon_pool_size, pool_size)

    # Atomics counter for round-robin poll selection
    counter = :atomics.new(1, signed: false)
    :persistent_term.put(:rcon_poll_counter, counter)

    children =
      [
        {Registry, keys: :unique, name: McFun.Rcon.Registry},
        {McFun.Rcon.Connection, name: :command}
      ] ++
        for i <- 1..pool_size do
          Supervisor.child_spec(
            {McFun.Rcon.Connection, name: {:poll, i}},
            id: {:rcon_poll, i}
          )
        end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
