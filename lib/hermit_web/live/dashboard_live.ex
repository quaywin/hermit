defmodule HermitWeb.DashboardLive do
  use HermitWeb, :live_view
  alias Hermit.Vpn.Form
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor

  @topic "vpn_pairs"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic)
      Registry.register(Hermit.Vpn.Registry, {:ui_session, self()}, :active)
    end

    pairs = PairWorker.list_pairs()
    error_tunnels = Enum.filter(pairs, fn p -> p.ts_status == :error or p.wg_status == :error end)
    inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)
    outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)

    {:ok,
     socket
     |> stream(:vpn_pairs, pairs)
     |> assign(error_tunnels: error_tunnels)
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
        current_errors = socket.assigns[:error_tunnels] || []
        updated_errors = Enum.reject(current_errors, &(&1.id == id))

        {:noreply,
         socket
         |> assign(error_tunnels: updated_errors)
         |> stream_delete(:vpn_pairs, %{id: id})
         |> put_flash(:info, "VPN Pair '#{id}' deleted.")}
    end
  end

  # --- PubSub Handling ---

  @impl true
  def handle_info({:vpn_pair_updated, state}, socket) do
    current_errors = socket.assigns[:error_tunnels] || []

    updated_errors =
      current_errors
      |> Enum.reject(&(&1.id == state.id))
      |> then(fn list ->
        if state.ts_status == :error or state.wg_status == :error do
          [state | list]
        else
          list
        end
      end)

    {:noreply,
     socket
     |> assign(error_tunnels: updated_errors)
     |> stream_insert(:vpn_pairs, state)}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, id}, socket) do
    current_errors = socket.assigns[:error_tunnels] || []
    updated_errors = Enum.reject(current_errors, &(&1.id == id))

    {:noreply,
     socket
     |> assign(error_tunnels: updated_errors)
     |> stream_delete(:vpn_pairs, %{id: id})}
  end

  # --- Helpers ---

  def summarize_error(nil), do: ""

  def summarize_error(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "Auth Key") -> "Auth Key Invalid / Expired"
      String.contains?(reason, "ACL Tag") -> "ACL Tag Not Found"
      String.contains?(reason, "Handshake Refused") -> "Handshake Refused"
      String.contains?(reason, "Handshake Timeout") -> "Handshake Timeout"
      String.contains?(reason, "Node Key") -> "Node Key Expired"
      true -> String.slice(reason, 0, 45)
    end
  end

  def summarize_error(reason), do: inspect(reason) |> String.slice(0, 45)

  defp assign_form(socket) do
    changeset = Form.changeset(%Form{}, %{})
    assign(socket, form: to_form(changeset))
  end

  def format_bytes(bytes), do: Hermit.format_bytes(bytes)
end
