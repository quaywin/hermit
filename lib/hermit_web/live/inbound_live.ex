defmodule HermitWeb.InboundLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.InboundProfile
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    inbound_profiles = Hermit.Repo.all(InboundProfile)
    dns_profiles = Hermit.Repo.all(from(d in Hermit.Vpn.DnsConfig, order_by: d.name))

    {:ok,
     socket
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(dns_profiles: dns_profiles)
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
    params = clean_dns_params(params)

    changeset =
      %InboundProfile{}
      |> InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_inbound", %{"inbound_profile" => params}, socket) do
    params = clean_dns_params(params)
    changeset = InboundProfile.changeset(%InboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        InboundProfile.clear_cache()
        inbound_profiles = Hermit.Repo.all(InboundProfile)
        dns_profiles = Hermit.Repo.all(from(d in Hermit.Vpn.DnsConfig, order_by: d.name))

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile created successfully.")
         |> assign(inbound_profiles: inbound_profiles)
         |> assign(dns_profiles: dns_profiles)
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
      # Stop DNS components if running
      if profile.type == "tailscale" do
        dns_config = Hermit.Vpn.DnsConfig.get_for_profile(profile.id)

        if dns_config.tailscale_override_dns do
          Task.start(fn -> Hermit.Vpn.DnsWorker.clear_tailscale_dns_config(dns_config) end)
        end
      end

      Hermit.Vpn.DnsSupervisor.stop_dns(profile.id)

      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          InboundProfile.clear_cache()
          inbound_profiles = Hermit.Repo.all(InboundProfile)
          dns_profiles = Hermit.Repo.all(from(d in Hermit.Vpn.DnsConfig, order_by: d.name))

          {:noreply,
           socket
           |> put_flash(:info, "Inbound Profile deleted.")
           |> assign(inbound_profiles: inbound_profiles, dns_profiles: dns_profiles)}

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
end
