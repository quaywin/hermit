defmodule Hermit.Vpn.PairMetrics do
  @moduledoc """
  Metrics defaults, UI-aware polling cadence, inbound metadata refresh checks,
  and overall status derivation for VPN pairs.
  """

  @default_metrics %{
    bytes_received: 0,
    bytes_sent: 0,
    ts_ips: [],
    ts_backend_state: "Offline",
    ts_user: "Unknown",
    ts_magic_dns: "",
    ts_exit_node: false,
    wg_port: nil,
    latency: nil
  }

  def default_metrics, do: @default_metrics

  def poll_interval_ms do
    if has_active_ui?(), do: 3000, else: 10_000
  end

  def should_poll_inbound?(state) do
    now = System.system_time(:second)
    last_poll = Map.get(state.metrics || %{}, :inbound_fetched_at, 0)

    now - last_poll >= 300 or not has_inbound_info?(state.metrics || %{}, state.inbound_module)
  end

  def has_inbound_info?(metrics, Hermit.Vpn.Inbound.Tailscale) do
    metrics[:ts_ips] != [] and metrics[:ts_backend_state] == "Running"
  end

  def has_inbound_info?(metrics, Hermit.Vpn.Inbound.Proxy) do
    metrics[:proxy_port] != nil and metrics[:proxy_status] == "Running"
  end

  def has_inbound_info?(_metrics, _module), do: false

  def has_active_ui? do
    match_spec = [
      {{{:ui_session, :_}, :_, :_}, [], [true]},
      {{:"$1", :_, :_},
       [
         {:andalso, {:is_binary, :"$1"},
          {:andalso, {:>=, {:byte_size, :"$1"}, 11},
           {:==, {:binary_part, :"$1", 0, 11}, "ui_session:"}}}
       ], [true]}
    ]

    try do
      case Registry.select(Hermit.Vpn.Registry, match_spec) do
        [_ | _] -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  def compute_overall_status(state) do
    cond do
      state.wg_status == :error ->
        {:error, state.wg_error_reason}

      state.ts_status == :error ->
        {:error, state.ts_error_reason}

      state.wg_status == :running and state.ts_status == :running ->
        {:running, nil}

      state.wg_status == :starting ->
        {:starting_wg, nil}

      state.ts_status == :starting ->
        {:starting_ts, nil}

      state.wg_status == :stopped and state.ts_status == :stopped ->
        {:stopped, nil}

      true ->
        {:stopped, nil}
    end
  end
end
