defmodule HermitWeb.DashboardLive do
  use HermitWeb, :live_view
  alias Hermit.Vpn.Form
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor
  require Logger

  @topic "vpn_pairs"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic)
    end

    pairs = PairWorker.list_pairs()
    inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)
    outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)

    {:ok,
     socket
     |> stream(:vpn_pairs, pairs)
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(outbound_profiles: outbound_profiles)
     |> assign(show_create_modal: false)
     |> assign_form()}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  @impl true
  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_create_modal: false)
     |> assign_form()}
  end

  # --- VPN Pair Management ---

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    changeset =
      %Form{}
      |> Form.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    changeset = Form.changeset(%Form{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, data} ->
        case Hermit.Vpn.VpnPair.check_outbound_conflict(data.outbound_profile_id, data.pair_id) do
          {:error, conflicting_id} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cannot start VPN Pair: Outbound profile is already in use by active tunnel '#{conflicting_id}'."
             )}

          :ok ->
            case DynamicSupervisor.start_pair(%{
                   id: data.pair_id,
                   inbound_profile_id: data.inbound_profile_id,
                   outbound_profile_id: data.outbound_profile_id
                 }) do
              {:ok, _pid} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "VPN Pair '#{data.pair_id}' started bootstrapping.")
                 |> assign(show_create_modal: false)
                 |> assign_form()}

              {:error, {:already_started, _}} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "VPN Pair with ID '#{data.pair_id}' is already running."
                 )}

              {:error, reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to start VPN Pair: #{inspect(reason)}")}
            end
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("start_tunnel", %{"id" => id}, socket) do
    vpn_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, id)

    case Hermit.Vpn.VpnPair.check_outbound_conflict(vpn_pair.outbound_profile_id, id) do
      {:error, conflicting_id} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to start Tunnel '#{id}': Outbound profile is already in use by active tunnel '#{conflicting_id}'."
         )}

      :ok ->
        case PairWorker.resume_pair(id) do
          {:ok, _pair} ->
            {:noreply, put_flash(socket, :info, "Tunnel '#{id}' starting...")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to start Tunnel '#{id}': #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("stop_tunnel", %{"id" => id}, socket) do
    case PairWorker.pause_pair(id) do
      {:ok, _pair} ->
        {:noreply, put_flash(socket, :info, "Tunnel '#{id}' stopped.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop Tunnel '#{id}': #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("restart_tunnel", %{"id" => id}, socket) do
    vpn_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, id)

    case Hermit.Vpn.VpnPair.check_outbound_conflict(vpn_pair.outbound_profile_id, id) do
      {:error, conflicting_id} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to restart Tunnel '#{id}': Outbound profile is already in use by active tunnel '#{conflicting_id}'."
         )}

      :ok ->
        case PairWorker.restart_pair(id) do
          {:ok, _pair} ->
            {:noreply, put_flash(socket, :info, "Tunnel '#{id}' restarting...")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to restart Tunnel '#{id}': #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case DynamicSupervisor.stop_pair(id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "VPN Pair '#{id}' deleted.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> stream_delete(:vpn_pairs, %{id: id})
         |> put_flash(:info, "VPN Pair '#{id}' deleted.")}
    end
  end

  # --- PubSub Handling ---

  @impl true
  def handle_info({:vpn_pair_updated, state}, socket) do
    {:noreply, stream_insert(socket, :vpn_pairs, state)}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, id}, socket) do
    {:noreply, stream_delete(socket, :vpn_pairs, %{id: id})}
  end

  # --- Helpers ---

  defp assign_form(socket) do
    changeset = Form.changeset(%Form{}, %{})
    assign(socket, form: to_form(changeset))
  end

  def format_uptime(nil), do: "-"

  def format_uptime(started_at) do
    diff = max(0, System.system_time(:second) - started_at)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{rem(div(diff, 60), 60)}m"
    end
  end

  def format_bytes(nil), do: "0 B"

  def format_bytes(bytes) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      true -> "#{Float.round(bytes / (1024 * 1024), 2)} MiB"
    end
  end

  def format_dns_time(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> "-"
    end
  end
end
