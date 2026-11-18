defmodule HermitWeb.DnsRulesLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsConfig
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
     |> assign(search_query: "")
     |> assign(filter_action: "all")
     |> assign(custom_rule_action: "route_tunnel")
     |> assign(custom_rule_domain: "")
     |> assign(custom_rule_value: "")
     |> assign(custom_rule_proxy_pair_id: "")}
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
    {:noreply, push_patch(socket, to: ~p"/dns/rules?profile_id=#{id_str}")}
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
    profile = socket.assigns.selected_profile

    if is_nil(profile) do
      {:noreply, socket}
    else
      domain = String.trim(params["domain"] || "") |> String.downcase()
      action = params["action"]
      value = params["value"]
      proxy_pair_id = params["proxy_pair_id"]

      cond do
        domain == "" ->
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
          # Clean domain prefix
          clean_domain =
            if String.starts_with?(domain, "*.") do
              domain
            else
              domain
            end

          existing_rules = profile.custom_rules || []
          # Remove old rule for this domain if exists
          filtered_rules =
            Enum.reject(existing_rules, fn r ->
              (r["domain"] || r[:domain]) == clean_domain
            end)

          new_rule = %{
            "domain" => clean_domain,
            "action" => action,
            "value" => if(action in ["block", "bypass"], do: nil, else: value),
            "proxy_pair_id" => if(action == "forward_dns", do: proxy_pair_id, else: nil)
          }

          updated_rules = [new_rule | filtered_rules]

          case DnsConfig.changeset(profile, %{custom_rules: updated_rules})
               |> Hermit.Repo.update() do
            {:ok, updated_profile} ->
              # Sync ETS and tunnels
              SniProxy.sync_all_routes()

              if :erlang.whereis(Hermit.PubSub) != :undefined do
                Phoenix.PubSub.broadcast(
                  Hermit.PubSub,
                  "dns_config_profile:#{updated_profile.id}",
                  {:dns_config_updated, updated_profile}
                )
              end

              reloaded =
                updated_profile |> Hermit.Repo.preload([:dns_endpoints], force: true)

              {:noreply,
               socket
               |> assign(selected_profile: reloaded)
               |> assign(custom_rule_domain: "")
               |> assign(custom_rule_value: "")
               |> assign(custom_rule_proxy_pair_id: "")
               |> put_flash(:info, "Rule for #{clean_domain} added successfully.")}

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
  end

  @impl true
  def handle_event("delete_custom_rule", %{"domain" => domain}, socket) do
    profile = socket.assigns.selected_profile

    if is_nil(profile) do
      {:noreply, socket}
    else
      existing_rules = profile.custom_rules || []

      updated_rules =
        Enum.reject(existing_rules, fn r ->
          (r["domain"] || r[:domain]) == domain
        end)

      case DnsConfig.changeset(profile, %{custom_rules: updated_rules})
           |> Hermit.Repo.update() do
        {:ok, updated_profile} ->
          SniProxy.sync_all_routes()

          if :erlang.whereis(Hermit.PubSub) != :undefined do
            Phoenix.PubSub.broadcast(
              Hermit.PubSub,
              "dns_config_profile:#{updated_profile.id}",
              {:dns_config_updated, updated_profile}
            )
          end

          reloaded =
            updated_profile |> Hermit.Repo.preload([:dns_endpoints], force: true)

          {:noreply,
           socket
           |> assign(selected_profile: reloaded)
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
