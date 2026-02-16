defmodule McFun.Redstone.CircuitRegistry do
  @moduledoc """
  GenServer backed by ETS for storing named redstone circuit definitions.

  Circuits are maps with:
  - `:name` — unique identifier (alphanumeric + underscore)
  - `:type` — `:redstone`, `:command_block`, or `:combined`
  - `:origin` — `%{x: int, y: int, z: int}` base world coordinate
  - `:blocks` — list of block definitions (relative positions)
  - `:trigger` — `%{x: int, y: int, z: int}` relative trigger position
  """
  use GenServer
  require Logger

  @table :mc_fun_circuits
  @valid_name_pattern ~r/^[a-zA-Z0-9_]+$/

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a named circuit definition."
  @spec register_circuit(String.t(), map()) :: :ok | {:error, term()}
  def register_circuit(name, circuit_def) do
    GenServer.call(__MODULE__, {:register, name, circuit_def})
  end

  @doc "Retrieve a circuit by name."
  @spec get_circuit(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_circuit(name) do
    case :ets.lookup(@table, name) do
      [{^name, circuit}] -> {:ok, circuit}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all registered circuit names."
  @spec list_circuits() :: [String.t()]
  def list_circuits do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc "Delete a circuit by name."
  @spec delete_circuit(String.t()) :: :ok
  def delete_circuit(name) do
    :ets.delete(@table, name)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    Logger.info("CircuitRegistry started")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, name, circuit_def}, _from, state) do
    with :ok <- validate_name(name),
         :ok <- validate_circuit(circuit_def) do
      circuit = Map.put(circuit_def, :name, name)
      :ets.insert(@table, {name, circuit})
      Logger.info("Circuit registered: #{name}")
      {:reply, :ok, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  # Validation

  defp validate_name(name) do
    if is_binary(name) and Regex.match?(@valid_name_pattern, name),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp validate_circuit(def) do
    with :ok <- validate_field(def, :origin),
         :ok <- validate_field(def, :blocks),
         :ok <- validate_field(def, :trigger) do
      :ok
    end
  end

  defp validate_field(map, key) do
    if Map.has_key?(map, key), do: :ok, else: {:error, {:missing_field, key}}
  end
end
