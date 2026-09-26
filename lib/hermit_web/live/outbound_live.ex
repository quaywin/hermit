defmodule HermitWeb.OutboundLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.OutboundProfile
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    outbound_profiles = Hermit.Repo.all(OutboundProfile)
    provider_configs = Hermit.Repo.all(Hermit.Vpn.ProviderConfig) |> Enum.sort_by(& &1.name)

    {:ok,
     socket
     |> assign(outbound_profiles: outbound_profiles)
     |> assign(provider_configs: provider_configs)
     |> assign(selected_provider_config_id: "")
     |> assign(show_create_modal: false)
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)
     |> assign_outbound_form()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    provider_configs = Hermit.Repo.all(Hermit.Vpn.ProviderConfig) |> Enum.sort_by(& &1.name)

    {:noreply,
     assign(socket,
       show_create_modal: true,
       provider_configs: provider_configs,
       selected_provider_config_id: ""
     )}
  end

  @impl true
  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_create_modal: false)
     |> assign(selected_provider_config_id: "")
     |> assign_outbound_form()}
  end

  @impl true
  def handle_event("validate_outbound", %{"outbound_profile" => params}, socket) do
    changeset =
      %OutboundProfile{}
      |> OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_outbound", %{"outbound_profile" => params}, socket) do
    changeset = OutboundProfile.changeset(%OutboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        outbound_profiles = Hermit.Repo.all(OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile created successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign(show_create_modal: false)
         |> assign(selected_provider_config_id: "")
         |> assign_outbound_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(OutboundProfile, id)
    changeset = OutboundProfile.changeset(profile, %{})
    provider_configs = Hermit.Repo.all(Hermit.Vpn.ProviderConfig) |> Enum.sort_by(& &1.name)

    {:noreply,
     socket
     |> assign(editing_outbound_profile: profile)
     |> assign(editing_outbound_form: to_form(changeset))
     |> assign(provider_configs: provider_configs)
     |> assign(selected_provider_config_id: "")}
  end

  @impl true
  def handle_event("close_edit_outbound", _params, socket) do
    {:noreply,
     socket
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)
     |> assign(selected_provider_config_id: "")}
  end

  @impl true
  def handle_event("validate_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile

    changeset =
      profile
      |> OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile
    changeset = OutboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, updated_profile} ->
        sync_and_restart_linked_vpn_pairs(updated_profile)
        outbound_profiles = Hermit.Repo.all(OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile updated successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign(editing_outbound_profile: nil)
         |> assign(editing_outbound_form: nil)
         |> assign(selected_provider_config_id: "")}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(OutboundProfile, id)

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
          outbound_profiles = Hermit.Repo.all(OutboundProfile)

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
  def handle_event("select_provider_config", params, socket) do
    id = Map.get(params, "provider_config_id") || Map.get(params, "id") || ""
    provider_configs = socket.assigns.provider_configs

    case Enum.find(provider_configs, fn c -> to_string(c.id) == id end) do
      nil ->
        {:noreply, assign(socket, selected_provider_config_id: id)}

      config ->
        wg_config = config.config["wg_config"] || config.config[:wg_config] || ""

        socket =
          if socket.assigns.editing_outbound_profile do
            profile = socket.assigns.editing_outbound_profile
            # Build changes
            attrs = %{
              "name" => config.name,
              "type" => "wireguard",
              "config" => %{"wg_config" => wg_config}
            }

            changeset = OutboundProfile.changeset(profile, attrs)
            assign(socket, editing_outbound_form: to_form(changeset))
          else
            attrs = %{
              "name" => config.name,
              "type" => "wireguard",
              "config" => %{"wg_config" => wg_config}
            }

            changeset = OutboundProfile.changeset(%OutboundProfile{type: "wireguard"}, attrs)
            assign(socket, outbound_form: to_form(changeset))
          end

        {:noreply, assign(socket, selected_provider_config_id: id)}
    end
  end

  # --- Helpers ---

  defp assign_outbound_form(socket) do
    changeset = OutboundProfile.changeset(%OutboundProfile{type: "wireguard"}, %{})
    assign(socket, outbound_form: to_form(changeset))
  end

  defp sync_and_restart_linked_vpn_pairs(updated_profile) do
    pairs =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair, where: p.outbound_profile_id == ^updated_profile.id)
      )

    profile_keys = [
      "wg_config",
      "local_ip",
      "host_ip"
    ]

    Enum.each(pairs, fn pair ->
      existing_config = pair.outbound_config || %{}

      cleaned_config =
        Map.drop(
          existing_config,
          profile_keys ++ Enum.map(profile_keys, &String.to_atom/1)
        )

      new_pair_config = Map.merge(cleaned_config, updated_profile.config || %{})

      pair
      |> Hermit.Vpn.VpnPair.changeset(%{
        outbound_type: updated_profile.type,
        outbound_config: new_pair_config
      })
      |> Hermit.Repo.update!()

      case GenServer.whereis({:via, Registry, {Hermit.Vpn.Registry, pair.pair_id}}) do
        nil ->
          :ok

        pid ->
          try do
            state = GenServer.call(pid, :get_state)

            if state.wg_status in [:running, :starting, :error] do
              Hermit.Vpn.PairWorker.restart_pair(pair.pair_id)
            else
              DynamicSupervisor.terminate_child(Hermit.Vpn.DynamicSupervisor, pid)
            end
          catch
            :exit, _ -> :ok
          end
      end
    end)
  end
end
