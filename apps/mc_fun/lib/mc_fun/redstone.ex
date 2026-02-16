defmodule McFun.Redstone do
  @moduledoc """
  Public API for the redstone circuit system.

  Manage named circuits: create, place in-world, activate/deactivate, remove.

  ## Usage

      circuit = %{
        type: :command_block,
        origin: %{x: 100, y: 64, z: 200},
        blocks: [
          %{pos: %{x: 0, y: 0, z: 0}, block: "stone"},
          %{pos: %{x: 0, y: 1, z: 0}, block: "command_block",
            facing: "up", auto: false, command: "say hello"}
        ],
        trigger: %{x: 0, y: 0, z: -1}
      }

      McFun.Redstone.create_circuit("door_1", circuit)
      McFun.Redstone.place("door_1")
      McFun.Redstone.activate("door_1")
      McFun.Redstone.deactivate("door_1")
      McFun.Redstone.remove("door_1")
  """

  alias McFun.Redstone.{CircuitRegistry, Executor}

  @doc "Register a named circuit definition."
  @spec create_circuit(String.t(), map()) :: :ok | {:error, term()}
  def create_circuit(name, circuit_def) do
    CircuitRegistry.register_circuit(name, circuit_def)
  end

  @doc "Place all blocks of a named circuit in the world."
  @spec place(String.t()) :: :ok | {:error, term()}
  def place(name) do
    with {:ok, circuit} <- CircuitRegistry.get_circuit(name) do
      Executor.place_circuit(circuit)
    end
  end

  @doc "Activate a named circuit (place redstone block at trigger)."
  @spec activate(String.t()) :: :ok | {:error, term()}
  def activate(name) do
    with {:ok, circuit} <- CircuitRegistry.get_circuit(name) do
      Executor.activate(circuit)
    end
  end

  @doc "Deactivate a named circuit (remove trigger block)."
  @spec deactivate(String.t()) :: :ok | {:error, term()}
  def deactivate(name) do
    with {:ok, circuit} <- CircuitRegistry.get_circuit(name) do
      Executor.deactivate(circuit)
    end
  end

  @doc "Remove all blocks of a named circuit from the world."
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(name) do
    with {:ok, circuit} <- CircuitRegistry.get_circuit(name) do
      Executor.remove_circuit(circuit)
    end
  end

  @doc "List all registered circuit names."
  @spec list() :: [String.t()]
  def list do
    CircuitRegistry.list_circuits()
  end

  @doc "Delete a circuit definition from the registry (does not remove blocks)."
  @spec delete(String.t()) :: :ok
  def delete(name) do
    CircuitRegistry.delete_circuit(name)
  end

  @doc "Convenience: place a single command block at absolute coordinates."
  @spec place_command_block(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def place_command_block(pos, command, opts \\ []) do
    facing = Keyword.get(opts, :facing, "north")
    auto = Keyword.get(opts, :auto, false)

    block_def = %{
      pos: %{x: 0, y: 0, z: 0},
      block: "command_block",
      facing: facing,
      auto: auto,
      command: command
    }

    circuit = %{origin: pos, blocks: [block_def], trigger: %{x: 0, y: 0, z: 0}}
    Executor.place_circuit(circuit)
  end
end
