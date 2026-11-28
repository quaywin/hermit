defmodule HermitWeb.DnsRulesLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsConfig

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
     |> assign(search_query: "")
     |> assign(filter_action: "all")
     |> assign(show_add_modal: false)
     |> assign(custom_rule_action: "route_tunnel")
     |> assign(custom_rule_domain: "")
     |> assign(custom_rule_value: "")
     |> assign(custom_rule_proxy_pair_id: "")}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_add_modal", _params, socket) do
    first_pair = List.first(socket.assigns.vpn_pairs)
    default_val = if first_pair, do: first_pair.pair_id, else: ""

    {:noreply,
     socket
     |> assign(show_add_modal: true)
     |> assign(custom_rule_action: "route_tunnel")
     |> assign(custom_rule_domain: "")
     |> assign(custom_rule_value: default_val)
     |> assign(custom_rule_proxy_pair_id: "")}
  end

  @impl true
  def handle_event("close_add_modal", _params, socket) do
    {:noreply, assign(socket, show_add_modal: false)}
  end

  @impl true
  def handle_event("filter_action", %{"action" => action}, socket) do
    {:noreply, assign(socket, filter_action: action)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("custom_rule_form_changed", params, socket) do
    action = params["action"] || socket.assigns.custom_rule_action
    domain = params["domain"] || socket.assigns.custom_rule_domain
    value = params["value"] || socket.assigns.custom_rule_value
    proxy_pair_id = params["proxy_pair_id"] || socket.assigns.custom_rule_proxy_pair_id

    # If action is route_tunnel and value is empty, default to first available tunnel
    value =
      if action == "route_tunnel" and (value == "" or is_nil(value)) do
        first_pair = List.first(socket.assigns.vpn_pairs)
        if first_pair, do: first_pair.pair_id, else: ""
      else
        value
      end

    {:noreply,
     socket
     |> assign(custom_rule_action: action)
     |> assign(custom_rule_domain: domain)
     |> assign(custom_rule_value: value)
     |> assign(custom_rule_proxy_pair_id: proxy_pair_id)}
  end

  @impl true
  def handle_event("add_custom_rule", params, socket) do
    config = socket.assigns.config
    raw_domain = params["domain"] || ""

    domains =
      raw_domain
      |> String.split([",", "\n", "\r", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    action = params["action"]
    value = params["value"]
    proxy_pair_id = params["proxy_pair_id"]

    cond do
      domains == [] ->
        {:noreply, put_flash(socket, :error, "Domain cannot be empty.")}

      action in ["redirect", "forward_dns", "route_tunnel"] and (is_nil(value) or value == "") ->
        msg =
          case action do
            "route_tunnel" -> "Please select a target tunnel."
            "redirect" -> "Target IP is required for redirect action."
            "forward_dns" -> "DNS Server IP or URL is required."
          end

        {:noreply, put_flash(socket, :error, msg)}

      true ->
        existing_rules = config.custom_rules || []
        domain_set = MapSet.new(domains)

        # Remove old rule for these domains if exists
        filtered_rules =
          Enum.reject(existing_rules, fn r ->
            MapSet.member?(domain_set, r["domain"] || r[:domain])
          end)

        new_rules =
          Enum.map(domains, fn d ->
            %{
              "domain" => d,
              "action" => action,
              "value" => if(action in ["block", "bypass"], do: nil, else: value),
              "proxy_pair_id" => if(action == "forward_dns", do: proxy_pair_id, else: nil),
              "enabled" => true
            }
          end)

        updated_rules = new_rules ++ filtered_rules

        case DnsConfig.update_global_rules(updated_rules) do
          {:ok, updated_config} ->
            {:noreply,
             socket
             |> assign(config: updated_config)
             |> assign(show_add_modal: false)
             |> assign(custom_rule_domain: "")
             |> assign(custom_rule_value: "")
             |> assign(custom_rule_proxy_pair_id: "")
             |> put_flash(:info, "Rule(s) for #{Enum.join(domains, ", ")} added successfully.")}

          {:error, changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to save rule: #{inspect(changeset.errors)}"
             )}
        end
    end
  end

  @impl true
  def handle_event("toggle_custom_rule", %{"domain" => domain}, socket) do
    config = socket.assigns.config
    existing_rules = config.custom_rules || []

    {updated_rules, new_enabled} =
      Enum.map_reduce(existing_rules, nil, fn rule, acc ->
        if (rule["domain"] || rule[:domain]) == domain do
          next_state = not DnsConfig.rule_enabled?(rule)
          {Map.put(rule, "enabled", next_state), next_state}
        else
          {rule, acc}
        end
      end)

    if is_nil(new_enabled) do
      {:noreply, put_flash(socket, :error, "Rule for #{domain} not found.")}
    else
      case DnsConfig.update_global_rules(updated_rules) do
        {:ok, updated_config} ->
          status_label = if new_enabled, do: "enabled", else: "disabled"

          {:noreply,
           socket
           |> assign(config: updated_config)
           |> put_flash(:info, "Rule for #{domain} #{status_label}.")}

        {:error, changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to update rule: #{inspect(changeset.errors)}"
           )}
      end
    end
  end

  @impl true
  def handle_event("delete_custom_rule", %{"domain" => domain}, socket) do
    config = socket.assigns.config
    existing_rules = config.custom_rules || []

    updated_rules =
      Enum.reject(existing_rules, fn r ->
        (r["domain"] || r[:domain]) == domain
      end)

    case DnsConfig.update_global_rules(updated_rules) do
      {:ok, updated_config} ->
        {:noreply,
         socket
         |> assign(config: updated_config)
         |> put_flash(:info, "Rule for #{domain} deleted.")}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to delete rule: #{inspect(changeset.errors)}"
         )}
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

  # Helpers
  def filter_rules(rules, filter_action, query) do
    rules = rules || []

    # 1. Action filter
    rules =
      if filter_action == "all" do
        rules
      else
        Enum.filter(rules, fn r -> (r["action"] || r[:action]) == filter_action end)
      end

    # 2. Text query filter
    if query == "" do
      rules
    else
      q = String.downcase(query)

      Enum.filter(rules, fn r ->
        domain = String.downcase(r["domain"] || r[:domain] || "")
        val = String.downcase(to_string(r["value"] || r[:value] || ""))
        String.contains?(domain, q) or String.contains?(val, q)
      end)
    end
  end

  def count_action(rules, "all"), do: length(rules || [])

  def count_action(rules, action) do
    Enum.count(rules || [], fn r -> (r["action"] || r[:action]) == action end)
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
