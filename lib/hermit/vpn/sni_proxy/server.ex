defmodule Hermit.Vpn.SniProxy.Server do
  @moduledoc """
  TCP Listener for the SNI Proxy.
  Listens on port 443 (HTTPS) and port 80 (HTTP) to intercept and relay
  Smart Routed domain traffic transparently.
  """
  use GenServer
  require Logger
  alias Hermit.Vpn.SniProxy
  alias Hermit.Vpn.SniProxy.Handler

  defstruct [
    :https_port,
    :http_port,
    :https_socket,
    :http_socket,
    :https_acceptor,
    :http_acceptor
  ]

  @default_https_port 443
  @default_http_port 80

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # Initialize the ETS table
    SniProxy.init_table()

    config = Application.get_env(:hermit, :sni_proxy, [])
    enabled? = Keyword.get(opts, :enabled, Keyword.get(config, :enabled, true))

    if enabled? do
      https_port = opts[:https_port] || Keyword.get(config, :https_port, @default_https_port)
      http_port = opts[:http_port] || Keyword.get(config, :http_port, @default_http_port)

      state = %__MODULE__{
        https_port: https_port,
        http_port: http_port
      }

      send(self(), :start_listeners)
      {:ok, state}
    else
      Logger.info("SNI Proxy Server is disabled by configuration.")
      {:ok, %__MODULE__{}}
    end
  end

  @impl true
  def handle_info(:start_listeners, state) do
    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      nodelay: true,
      backlog: 1024,
      buffer: 65_536,
      recbuf: 65_536,
      sndbuf: 65_536,
      keepalive: true,
      send_timeout: 10_000,
      send_timeout_close: true
    ]

    https_socket =
      case :gen_tcp.listen(state.https_port, listen_opts) do
        {:ok, sock} ->
          Logger.info("SNI Proxy listening on HTTPS port #{state.https_port}")
          sock

        {:error, reason} ->
          Logger.warning(
            "SNI Proxy failed to bind HTTPS port #{state.https_port}: #{inspect(reason)}"
          )

          nil
      end

    http_socket =
      case :gen_tcp.listen(state.http_port, listen_opts) do
        {:ok, sock} ->
          Logger.info("SNI Proxy listening on HTTP port #{state.http_port}")
          sock

        {:error, reason} ->
          Logger.warning(
            "SNI Proxy failed to bind HTTP port #{state.http_port}: #{inspect(reason)}"
          )

          nil
      end

    https_acceptor = if https_socket, do: spawn_acceptor(https_socket, 443), else: nil
    http_acceptor = if http_socket, do: spawn_acceptor(http_socket, 80), else: nil

    {:noreply,
     %{
       state
       | https_socket: https_socket,
         http_socket: http_socket,
         https_acceptor: https_acceptor,
         http_acceptor: http_acceptor
     }}
  end

  # Handle acceptor loop termination / restart
  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.https_acceptor and not is_nil(state.https_socket) ->
        Logger.debug("SNI Proxy HTTPS acceptor died (#{inspect(reason)}), restarting...")
        new_acceptor = spawn_acceptor(state.https_socket, 443)
        {:noreply, %{state | https_acceptor: new_acceptor}}

      pid == state.http_acceptor and not is_nil(state.http_socket) ->
        Logger.debug("SNI Proxy HTTP acceptor died (#{inspect(reason)}), restarting...")
        new_acceptor = spawn_acceptor(state.http_socket, 80)
        {:noreply, %{state | http_acceptor: new_acceptor}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.https_socket, do: :gen_tcp.close(state.https_socket)
    if state.http_socket, do: :gen_tcp.close(state.http_socket)
    :ok
  end

  # ============================================================================
  # Acceptor Loop
  # ============================================================================

  defp spawn_acceptor(listen_socket, default_port) do
    spawn_link(fn -> acceptor_loop(listen_socket, default_port) end)
  end

  defp acceptor_loop(listen_socket, default_port) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn an isolated task to handle the connection
        {:ok, task_pid} =
          Task.start(fn ->
            receive do
              :start_handling ->
                Handler.handle(client_socket, default_port)
            after
              5000 ->
                :gen_tcp.close(client_socket)
            end
          end)

        case :gen_tcp.controlling_process(client_socket, task_pid) do
          :ok ->
            send(task_pid, :start_handling)

          {:error, reason} ->
            Logger.debug("SNI Proxy: controlling_process failed: #{inspect(reason)}")
            :gen_tcp.close(client_socket)
        end

        acceptor_loop(listen_socket, default_port)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("SNI Proxy accept failed: #{inspect(reason)}")
        acceptor_loop(listen_socket, default_port)
    end
  end
end
