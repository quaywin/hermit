defmodule HermitWeb.DnsServicesLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Services.Catalog

  @topic_vpn "vpn_pairs"

  @impl true
  def mount(_params, _session, socket) do
    config = DnsConfig.get_global_config()

    vpn_pairs =
      Hermit.Repo.all(from(p in Hermit.Vpn.VpnPair, order_by: p.pair_id))
      |> Hermit.Repo.preload([:inbound_profile, :outbound_profile])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic_vpn)
      Phoenix.PubSub.subscribe(Hermit.PubSub, "global_dns_rules")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{config.id}")
    end

    {:ok,
     socket
     |> assign(config: config)
     |> assign(vpn_pairs: vpn_pairs)
     |> assign(categories: Catalog.categories())
     |> assign(selected_category: :all)
     |> assign(search_query: "")
     |> assign(expanded_domains: MapSet.new())}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
    config = socket.assigns.config
    svc_id = params["service_id"]
    action = params["action"] || "bypass"
    pair_id = params["pair_id"]

    current_services = config.services || %{}

    updated_services =
      case action do
        "bypass" ->
          Map.delete(current_services, svc_id)

        "block" ->
          Map.put(current_services, svc_id, %{"action" => "block"})

        "route_tunnel" ->
          target_pair =
            if is_binary(pair_id) and pair_id != "" do
              pair_id
            else
              first_pair = List.first(socket.assigns.vpn_pairs)
              if first_pair, do: first_pair.pair_id, else: ""
            end

          Map.put(current_services, svc_id, %{
            "action" => "route_tunnel",
            "pair_id" => target_pair
          })

        _ ->
          current_services
      end

    case DnsConfig.update_global_services(updated_services) do
      {:ok, updated_config} ->
        svc = Catalog.get(svc_id)
        name = if svc, do: svc.name, else: svc_id

        action_desc =
          case action do
            "bypass" ->
              "direct connection (Bypass)"

            "block" ->
              "blocked"

            "route_tunnel" ->
              routed_to = get_in(updated_services, [svc_id, "pair_id"]) || pair_id || ""
              "routed via tunnel #{routed_to}"

            _ ->
              "updated"
          end

        {:noreply,
         socket
         |> assign(config: updated_config)
         |> put_flash(:info, "#{name} is now #{action_desc}.")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update service: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_info({:global_dns_rules_updated, updated_config}, socket) do
    {:noreply, assign(socket, config: updated_config)}
  end

  def handle_info({:dns_config_updated, updated_profile}, socket) do
    if socket.assigns.config && socket.assigns.config.id == updated_profile.id do
      {:noreply, assign(socket, config: updated_profile)}
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
