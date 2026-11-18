defmodule HermitWeb.DnsServicesLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Services.Catalog
  alias Hermit.Vpn.SniProxy

  @topic_vpn "vpn_pairs"

  @impl true
  def mount(_params, _session, socket) do
    dns_profiles =
      Hermit.Repo.all(from(d in DnsConfig, order_by: d.name))
      |> Hermit.Repo.preload([:dns_endpoints])

    selected_profile = List.first(dns_profiles)

    vpn_pairs =
      Hermit.Repo.all(from(p in Hermit.Vpn.VpnPair, order_by: p.pair_id))
      |> Hermit.Repo.preload([:inbound_profile, :outbound_profile])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic_vpn)

      if selected_profile do
        Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{selected_profile.id}")
      end
    end

    {:ok,
     socket
     |> assign(dns_profiles: dns_profiles)
     |> assign(selected_profile: selected_profile)
     |> assign(vpn_pairs: vpn_pairs)
     |> assign(categories: Catalog.categories())
     |> assign(selected_category: :all)
     |> assign(search_query: "")
     |> assign(expanded_domains: MapSet.new())}
  end

  @impl true
  def handle_params(%{"profile_id" => profile_id_str}, _uri, socket) do
    profile_id = String.to_integer(profile_id_str)

    profile =
      Hermit.Repo.get(DnsConfig, profile_id)
      |> Hermit.Repo.preload([:dns_endpoints])

    if socket.assigns.selected_profile && socket.assigns.selected_profile.id != profile.id do
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        Phoenix.PubSub.unsubscribe(
          Hermit.PubSub,
          "dns_config_profile:#{socket.assigns.selected_profile.id}"
        )

        Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{profile.id}")
      end
    end

    {:noreply, assign(socket, selected_profile: profile)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_profile", %{"id" => id_str}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dns/services?profile_id=#{id_str}")}
  end

  @impl true
  def handle_event("select_category", %{"category" => cat_str}, socket) do
    cat =
      try do
        String.to_existing_atom(cat_str)
      rescue
        ArgumentError -> :all
      end

    {:noreply, assign(socket, selected_category: cat)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("toggle_domains", %{"id" => svc_id}, socket) do
    expanded = socket.assigns.expanded_domains

    new_expanded =
      if MapSet.member?(expanded, svc_id) do
        MapSet.delete(expanded, svc_id)
      else
        MapSet.put(expanded, svc_id)
      end

    {:noreply, assign(socket, expanded_domains: new_expanded)}
  end

  @impl true
  def handle_event("set_service_action", params, socket) do
    profile = socket.assigns.selected_profile

    if is_nil(profile) do
      {:noreply, socket}
    else
      svc_id = params["service_id"]
      action = params["action"] || "bypass"
      pair_id = params["pair_id"]

      current_services = profile.services || %{}

      updated_services =
        case action do
          "bypass" ->
            # Bypass removes the override or sets to bypass
            Map.delete(current_services, svc_id)

          "block" ->
            Map.put(current_services, svc_id, %{"action" => "block"})

          "route_tunnel" ->
            if is_binary(pair_id) and pair_id != "" do
              Map.put(current_services, svc_id, %{
                "action" => "route_tunnel",
                "pair_id" => pair_id
              })
            else
              # If no pair selected, default to first available vpn pair or keep old
              first_pair = List.first(socket.assigns.vpn_pairs)
              default_id = if first_pair, do: first_pair.pair_id, else: ""

              Map.put(current_services, svc_id, %{
                "action" => "route_tunnel",
                "pair_id" => default_id
              })
            end

          _ ->
            current_services
        end

      case DnsConfig.changeset(profile, %{services: updated_services})
           |> Hermit.Repo.update() do
        {:ok, updated_profile} ->
          # 1. Sync ETS and Notify running pairs
          SniProxy.sync_all_routes()

          # 2. Broadcast to DNS servers
          if :erlang.whereis(Hermit.PubSub) != :undefined do
            Phoenix.PubSub.broadcast(
              Hermit.PubSub,
              "dns_config_profile:#{updated_profile.id}",
              {:dns_config_updated, updated_profile}
            )
          end

          # 3. Reload profile with preload
          reloaded_profile =
            updated_profile |> Hermit.Repo.preload([:dns_endpoints], force: true)

          # Find service name for nice toast
          svc = Catalog.get(svc_id)
          name = if svc, do: svc.name, else: svc_id

          action_desc =
            case action do
              "bypass" -> "direct connection (Bypass)"
              "block" -> "blocked"
              "route_tunnel" -> "routed via tunnel #{pair_id}"
              _ -> "updated"
            end

          {:noreply,
           socket
           |> assign(selected_profile: reloaded_profile)
           |> put_flash(:info, "#{name} is now #{action_desc}.")}

        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, "Failed to update service: #{inspect(changeset.errors)}")}
      end
    end
  end

  @impl true
  def handle_info({:dns_config_updated, updated_profile}, socket) do
    if socket.assigns.selected_profile &&
         socket.assigns.selected_profile.id == updated_profile.id do
      reloaded = updated_profile |> Hermit.Repo.preload([:dns_endpoints], force: true)
      {:noreply, assign(socket, selected_profile: reloaded)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:vpn_pair_updated, _pair}, socket) do
    vpn_pairs =
      Hermit.Repo.all(from(p in Hermit.Vpn.VpnPair, order_by: p.pair_id))
      |> Hermit.Repo.preload([:inbound_profile, :outbound_profile])

    {:noreply, assign(socket, vpn_pairs: vpn_pairs)}
  end

  def handle_info({:vpn_pair_deleted, _pair_id}, socket) do
    vpn_pairs =
      Hermit.Repo.all(from(p in Hermit.Vpn.VpnPair, order_by: p.pair_id))
      |> Hermit.Repo.preload([:inbound_profile, :outbound_profile])

    {:noreply, assign(socket, vpn_pairs: vpn_pairs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helper functions
  def get_filtered_services(category, search_query) do
    services =
      if category == :all do
        Catalog.all()
      else
        Catalog.by_category(category)
      end

    if search_query == "" do
      services
    else
      q = String.downcase(search_query)

      Enum.filter(services, fn svc ->
        String.contains?(String.downcase(svc.name), q) or
          String.contains?(svc.id, q) or
          Enum.any?(svc.domains, &String.contains?(&1, q))
      end)
    end
  end

  def service_state(services_map, service_id) do
    cfg = Map.get(services_map || %{}, service_id, %{})
    action = Map.get(cfg, "action") || Map.get(cfg, :action) || "bypass"
    pair_id = Map.get(cfg, "pair_id") || Map.get(cfg, :pair_id)

    %{action: action, pair_id: pair_id}
  end

  def format_tunnel_label(pair) do
    inbound_name =
      if Ecto.assoc_loaded?(pair.inbound_profile) and pair.inbound_profile,
        do: pair.inbound_profile.name,
        else: pair.inbound_type

    outbound_name =
      if Ecto.assoc_loaded?(pair.outbound_profile) and pair.outbound_profile,
        do: pair.outbound_profile.name,
        else: pair.outbound_type

    "#{pair.pair_id} (#{inbound_name} → #{outbound_name})"
  end
end
