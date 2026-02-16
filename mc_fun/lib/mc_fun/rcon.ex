defmodule McFun.Rcon do
  @moduledoc """
  RCON client GenServer implementing the Source RCON Protocol over TCP.

  Packet format: [length(4 LE) | id(4 LE) | type(4 LE) | body(null-terminated) | pad(1)]
  """
  use GenServer
  require Logger

  @login_type 3
  @command_type 2
  @response_type 0

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send an RCON command and return the response body."
  def command(cmd, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:command, cmd}, timeout)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:mc_fun, :rcon, [])
    host = Keyword.get(opts, :host, Keyword.get(config, :host, "localhost"))
    port = Keyword.get(opts, :port, Keyword.get(config, :port, 25575))
    password = Keyword.get(opts, :password, Keyword.get(config, :password, ""))

    state = %{
      host: host,
      port: port,
      password: password,
      socket: nil,
      request_id: 1,
      pending: %{}
    }

    case connect(state) do
      {:ok, state} ->
        case authenticate(state) do
          {:ok, state} ->
            Logger.info("RCON connected to #{host}:#{port}")
            {:ok, state}

          {:error, reason} ->
            Logger.error("RCON auth failed: #{inspect(reason)}")
            {:stop, {:auth_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("RCON connect failed: #{inspect(reason)}")
        {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def handle_call({:command, cmd}, from, state) do
    {id, state} = next_id(state)

    case send_packet(state.socket, id, @command_type, cmd) do
      :ok ->
        state = put_in(state.pending[id], from)
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    case parse_packet(data) do
      {:ok, id, _type, body} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            {:noreply, state}

          {from, pending} ->
            GenServer.reply(from, {:ok, body})
            {:noreply, %{state | pending: pending}}
        end

      {:error, reason} ->
        Logger.warning("RCON parse error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("RCON connection closed, reconnecting...")

    case reconnect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> {:stop, :connection_lost, state}
    end
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("RCON TCP error: #{inspect(reason)}")
    {:stop, {:tcp_error, reason}, state}
  end

  # Private

  defp connect(state) do
    host = to_charlist(state.host)
    opts = [:binary, active: true, packet: :raw]

    case :gen_tcp.connect(host, state.port, opts, 5_000) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticate(state) do
    {id, state} = next_id(state)

    with :ok <- send_packet(state.socket, id, @login_type, state.password) do
      # Minecraft sends an empty RESPONSE_VALUE packet, then the AUTH_RESPONSE.
      # Some servers only send the AUTH_RESPONSE. Read packets until we get type 2.
      read_auth_response(state, id, 3)
    end
  end

  defp read_auth_response(_state, _id, 0), do: {:error, :auth_timeout}

  defp read_auth_response(state, id, attempts) do
    case recv_packet(state.socket) do
      {:ok, ^id, @command_type, _body} -> {:ok, state}
      {:ok, -1, @command_type, _} -> {:error, :auth_failed}
      {:ok, _, @response_type, _} -> read_auth_response(state, id, attempts - 1)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp reconnect(state) do
    if state.socket, do: :gen_tcp.close(state.socket)

    # Reply to all pending callers so they don't block until timeout
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, :connection_lost})
    end

    state = %{state | socket: nil, pending: %{}}

    with {:ok, state} <- connect(state),
         {:ok, state} <- authenticate(state) do
      Logger.info("RCON reconnected")
      {:ok, state}
    end
  end

  defp next_id(state) do
    {state.request_id, %{state | request_id: state.request_id + 1}}
  end

  defp send_packet(socket, id, type, body) do
    payload = <<id::little-32, type::little-32>> <> body <> <<0, 0>>
    length = byte_size(payload)
    packet = <<length::little-32>> <> payload
    :gen_tcp.send(socket, packet)
  end

  defp recv_packet(socket, timeout \\ 5_000) do
    # Switch to passive temporarily for synchronous auth
    :inet.setopts(socket, active: false)

    result =
      with {:ok, <<length::little-32>>} <- :gen_tcp.recv(socket, 4, timeout),
           {:ok, data} <- :gen_tcp.recv(socket, length, timeout) do
        parse_packet(<<length::little-32>> <> data)
      end

    :inet.setopts(socket, active: true)
    result
  end

  defp parse_packet(<<length::little-32, rest::binary>>) when byte_size(rest) >= length do
    <<id::little-signed-32, type::little-32, rest::binary>> = rest
    # Body is null-terminated + 1 pad byte
    body_size = length - 10
    <<body::binary-size(body_size), 0, 0>> = rest
    {:ok, id, type, body}
  end

  defp parse_packet(_data), do: {:error, :incomplete_packet}
end
