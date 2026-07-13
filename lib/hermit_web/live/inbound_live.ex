defmodule HermitWeb.InboundLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.InboundProfile
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsWorker
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    inbound_profiles = Hermit.Repo.all(InboundProfile)

    {:ok,
     socket
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(show_create_modal: false)
     |> assign_inbound_form()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
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
     |> assign_inbound_form()}
  end

  @impl true
  def handle_event("validate_inbound", %{"inbound_profile" => params}, socket) do
    changeset =
      %InboundProfile{}
      |> InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_inbound", %{"inbound_profile" => params}, socket) do
    changeset = InboundProfile.changeset(%InboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        InboundProfile.clear_cache()
        inbound_profiles = Hermit.Repo.all(InboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile created successfully.")
         |> assign(inbound_profiles: inbound_profiles)
         |> assign(show_create_modal: false)
         |> assign_inbound_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_inbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(InboundProfile, id)

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
      # Dừng tất cả các DNS Endpoints đang sử dụng Inbound Profile này
      endpoints =
        Hermit.Repo.all(from(e in DnsEndpoint, where: e.inbound_profile_id == ^profile.id))

      Enum.each(endpoints, fn endpoint ->
        config = Hermit.Vpn.DnsConfig.get_for_endpoint(endpoint.id)

        if config && config.tailscale_override_dns do
          Task.start(fn -> DnsWorker.clear_tailscale_dns_config(config) end)
        end

        Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)

        # Cập nhật endpoint thành DoH Only (inbound_profile_id = nil) thay vì xóa
        endpoint
        |> DnsEndpoint.changeset(%{inbound_profile_id: nil, enabled: false})
        |> Hermit.Repo.update!()
      end)

      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          InboundProfile.clear_cache()
          DnsEndpoint.clear_cache()
          inbound_profiles = Hermit.Repo.all(InboundProfile)

          {:noreply,
           socket
           |> put_flash(:info, "Inbound Profile deleted. Linked DNS endpoints reverted to DoH.")
           |> assign(inbound_profiles: inbound_profiles)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

  # --- Helpers ---

  defp assign_inbound_form(socket) do
    changeset = InboundProfile.changeset(%InboundProfile{type: "tailscale"}, %{})
    assign(socket, inbound_form: to_form(changeset))
  end
end
