defmodule HermitWeb.DashboardLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.Form
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor

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
     |> assign(active_tab: :tunnels)
     |> assign(editing_inbound_profile: nil)
     |> assign(editing_inbound_form: nil)
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)
     |> assign_form()
     |> assign_inbound_form()
     |> assign_outbound_form()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_atom(tab))}
  end

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

  @impl true
  def handle_event("validate_inbound", %{"inbound_profile" => params}, socket) do
    params = clean_dns_params(params)
    changeset =
      %Hermit.Vpn.InboundProfile{}
      |> Hermit.Vpn.InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_inbound", %{"inbound_profile" => params}, socket) do
    params = clean_dns_params(params)
    changeset = Hermit.Vpn.InboundProfile.changeset(%Hermit.Vpn.InboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile created successfully.")
         |> assign(inbound_profiles: inbound_profiles)
         |> assign_inbound_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_inbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, id)
    changeset = Hermit.Vpn.InboundProfile.changeset(profile, %{})

    {:noreply,
     socket
     |> assign(editing_inbound_profile: profile)
     |> assign(editing_inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("close_edit_inbound", _params, socket) do
    {:noreply,
     socket
     |> assign(editing_inbound_profile: nil)
     |> assign(editing_inbound_form: nil)}
  end

  @impl true
  def handle_event("validate_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.editing_inbound_profile
    params = clean_dns_params(params)

    changeset =
      profile
      |> Hermit.Vpn.InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.editing_inbound_profile
    params = clean_dns_params(params)
    changeset = Hermit.Vpn.InboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, _profile} ->
        inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile updated successfully.")
         |> assign(inbound_profiles: inbound_profiles)
         |> assign(editing_inbound_profile: nil)
         |> assign(editing_inbound_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, id)
    changeset = Hermit.Vpn.OutboundProfile.changeset(profile, %{})

    {:noreply,
     socket
     |> assign(editing_outbound_profile: profile)
     |> assign(editing_outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("close_edit_outbound", _params, socket) do
    {:noreply,
     socket
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)}
  end

  @impl true
  def handle_event("validate_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile

    changeset =
      profile
      |> Hermit.Vpn.OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile
    changeset = Hermit.Vpn.OutboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, _profile} ->
        outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile updated successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign(editing_outbound_profile: nil)
         |> assign(editing_outbound_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_inbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, id)

    active_referencing_tunnels =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair,
          where: p.inbound_profile_id == ^profile.id
        )
      )

    if active_referencing_tunnels != [] do
      {:noreply,
       put_flash(socket, :error, "Cannot delete profile because it is in use by active tunnels.")}
    else
      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)

          {:noreply,
           socket
           |> put_flash(:info, "Inbound Profile deleted.")
           |> assign(inbound_profiles: inbound_profiles)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

  @impl true
  def handle_event("validate_outbound", %{"outbound_profile" => params}, socket) do
    changeset =
      %Hermit.Vpn.OutboundProfile{}
      |> Hermit.Vpn.OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_outbound", %{"outbound_profile" => params}, socket) do
    changeset = Hermit.Vpn.OutboundProfile.changeset(%Hermit.Vpn.OutboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile created successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign_outbound_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(Hermit.Vpn.OutboundProfile, id)

    active_referencing_tunnels =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair,
          where: p.outbound_profile_id == ^profile.id
        )
      )

    if active_referencing_tunnels != [] do
      {:noreply,
       put_flash(socket, :error, "Cannot delete profile because it is in use by active tunnels.")}
    else
      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)

          {:noreply,
           socket
           |> put_flash(:info, "Outbound Profile deleted.")
           |> assign(outbound_profiles: outbound_profiles)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

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

  defp assign_inbound_form(socket) do
    changeset =
      Hermit.Vpn.InboundProfile.changeset(%Hermit.Vpn.InboundProfile{type: "tailscale"}, %{})

    assign(socket, inbound_form: to_form(changeset))
  end

  defp assign_outbound_form(socket) do
    changeset =
      Hermit.Vpn.OutboundProfile.changeset(%Hermit.Vpn.OutboundProfile{type: "wireguard"}, %{})

    assign(socket, outbound_form: to_form(changeset))
  end

  defp clean_dns_params(params) do
    config = Map.get(params, "config")

    if is_map(config) do
      dns_mode = Map.get(config, "dns_mode")
      dns_resolvers = Map.get(config, "dns_resolvers", "") |> String.trim()

      {dns_mode, dns_resolvers} =
        cond do
          dns_mode == "custom" ->
            {"custom", dns_resolvers}

          dns_mode == "default" ->
            {"default", ""}

          dns_resolvers != "" ->
            {"custom", dns_resolvers}

          true ->
            {"default", ""}
        end

      updated_config =
        config
        |> Map.put("dns_mode", dns_mode)
        |> Map.put("dns_resolvers", dns_resolvers)

      Map.put(params, "config", updated_config)
    else
      params
    end
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
end
