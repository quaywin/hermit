defmodule HermitWeb.InboundDetailLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.InboundProfile
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.DnsWorker
  require Logger

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    id = String.to_integer(id_str)

    case Hermit.Repo.get(InboundProfile, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Inbound Profile '#{id}' not found.")
         |> push_navigate(to: ~p"/")}

      profile ->
        # Subscription for status polling
        if connected?(socket) and profile.type == "tailscale" do
          :timer.send_interval(1000, self(), :tick)
        end

        dns_config =
          if profile.type == "tailscale", do: DnsConfig.get_for_profile(profile.id), else: nil

        {dns_status, dns_ip, dns_error} =
          if profile.type == "tailscale",
            do: DnsWorker.get_status(profile.id),
            else: {:stopped, nil, nil}

        dns_profiles = Hermit.Repo.all(from(d in Hermit.Vpn.DnsConfig, order_by: d.name))

        changeset = InboundProfile.changeset(profile, %{})

        {:ok,
         socket
         |> assign(id: id)
         |> assign(profile: profile)
         |> assign(dns_config: dns_config)
         |> assign(dns_profiles: dns_profiles)
         |> assign(dns_status: dns_status)
         |> assign(dns_ip: dns_ip)
         |> assign(dns_error: dns_error)
         |> assign(custom_rule_action: "block")
         |> assign(vpn_pairs: [])
         |> assign(editing_inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    active_tab =
      case Map.get(params, "tab", "config") do
        "dns" when socket.assigns.profile.type == "tailscale" -> :dns
        "routing" when socket.assigns.profile.type == "tailscale" -> :routing
        _ -> :config
      end

    socket =
      if active_tab == :routing do
        reload_routing_tab(socket)
      else
        socket
      end

    {:noreply, assign(socket, active_tab: active_tab)}
  end

  @impl true
  def handle_event("validate_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.profile
    params = clean_dns_params(params)

    changeset =
      profile
      |> InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.profile
    params = clean_dns_params(params)
    changeset = InboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, updated_profile} ->
        # Reboot DNS node if it was running with old credentials
        if updated_profile.type == "tailscale" and
             DnsWorker.get_status(updated_profile.id) |> elem(0) == :running do
          Hermit.Vpn.DnsSupervisor.stop_dns(updated_profile.id)
          Hermit.Vpn.DnsSupervisor.start_dns(updated_profile.id)
        end

        changeset_new = InboundProfile.changeset(updated_profile, %{})

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile updated successfully.")
         |> assign(profile: updated_profile)
         |> assign(editing_inbound_form: to_form(changeset_new))}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_inbound", _params, socket) do
    profile = socket.assigns.profile

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
          {:noreply,
           socket
           |> put_flash(:info, "Inbound Profile deleted.")
           |> push_navigate(to: ~p"/")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

  @impl true
  def handle_event("toggle_dns_enabled", _params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    enabled = not config.enabled

    # If we are disabling DNS, we must also disable tailscale_override_dns
    update_params = if not enabled, do: %{enabled: false, tailscale_override_dns: false}, else: %{enabled: true}

    case DnsConfig.update_for_profile(profile_id, update_params) do
      {:ok, updated} ->
        if enabled do
          case Hermit.Vpn.DnsSupervisor.start_dns(profile_id) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.error("Failed to start DNS: #{inspect(reason)}")
          end
        else
          Hermit.Vpn.DnsSupervisor.stop_dns(profile_id)
        end

        {status, ip, err} = DnsWorker.get_status(profile_id)

        {:noreply,
         socket
         |> assign(dns_config: updated, dns_status: status, dns_ip: ip, dns_error: err)
         |> put_flash(
           :info,
           "DNS Filtering #{if enabled, do: "enabled", else: "disabled"} for profile."
         )}

      {:error, changeset} ->
        error_msg =
          case changeset.errors[:inbound_profile_id] do
            {msg, _} -> "Inbound Profile " <> msg
            _ -> "Failed to toggle DNS filtering"
          end

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("reconnect_dns", _params, socket) do
    profile_id = socket.assigns.id

    # Stop existing DNS worker to clean up previous run
    Hermit.Vpn.DnsSupervisor.stop_dns(profile_id)

    # Start DNS components
    case Hermit.Vpn.DnsSupervisor.start_dns(profile_id) do
      {:ok, _} ->
        {status, ip, err} = DnsWorker.get_status(profile_id)
        {:noreply,
         socket
         |> assign(dns_status: status, dns_ip: ip, dns_error: err)
         |> put_flash(:info, "Reconnecting DNS Node...")}

      {:error, reason} ->
        Logger.error("Failed to reconnect DNS: #{inspect(reason)}")
        {:noreply,
         socket
         |> put_flash(:error, "Failed to reconnect DNS: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_block_ads", _params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    block_ads = not config.block_ads

    case DnsConfig.update_for_profile(profile_id, %{block_ads: block_ads}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(
           :info,
           "Ads/Trackers blocking #{if block_ads, do: "enabled", else: "disabled"}!"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update ads blocking: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_block_adult", _params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    block_adult = not config.block_adult

    case DnsConfig.update_for_profile(profile_id, %{block_adult: block_adult}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(
           :info,
           "Adult content blocking #{if block_adult, do: "enabled", else: "disabled"}!"
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update adult content blocking: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_block_goodbyeads", _params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    block_goodbyeads = not config.block_goodbyeads

    case DnsConfig.update_for_profile(profile_id, %{block_goodbyeads: block_goodbyeads}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(
           :info,
           "GoodbyeAds blocking #{if block_goodbyeads, do: "enabled", else: "disabled"}!"
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update GoodbyeAds blocking: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_query_logging", _params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    enable_logging = not config.enable_query_logging

    case DnsConfig.update_for_profile(profile_id, %{enable_query_logging: enable_logging}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(
           :info,
           "Query logging #{if enable_logging, do: "enabled", else: "disabled"} for this profile."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle query logging.")}
    end
  end

  @impl true
  def handle_event("toggle_override_dns", _params, socket) do
    profile_id = socket.assigns.id
    {status, _, _} = DnsWorker.get_status(profile_id)

    if status != :running do
      {:noreply, put_flash(socket, :error, "Cannot toggle Override DNS when DNS Node is not running.")}
    else
      config = socket.assigns.dns_config
      override = not config.tailscale_override_dns

      case DnsConfig.update_for_profile(profile_id, %{tailscale_override_dns: override}) do
        {:ok, updated} ->
          case DnsWorker.sync_state(profile_id) do
            {:ok, _} ->
              :ok

            {:error, :not_found} ->
              if not override do
                Task.start(fn -> Hermit.Vpn.DnsWorker.clear_tailscale_dns_config(updated) end)
              end

              :ok
          end

          {:noreply,
           socket
           |> assign(dns_config: updated)
           |> put_flash(
             :info,
             "Tailscale DNS integration #{if override, do: "enabled", else: "disabled"}."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update Tailscale DNS integration.")}
      end
    end
  end

  @impl true
  def handle_event("select_dns_profile", %{"dns_profile_id" => dns_profile_id_str}, socket) do
    profile = socket.assigns.profile
    dns_profile_id = if dns_profile_id_str == "", do: nil, else: String.to_integer(dns_profile_id_str)

    changeset = InboundProfile.changeset(profile, %{dns_profile_id: dns_profile_id})

    case Hermit.Repo.update(changeset) do
      {:ok, updated_profile} ->
        # Load new dns config
        updated_dns_config = DnsConfig.get_for_profile(updated_profile.id)

        # Hot-reboot DNS server if running to load new config dynamically
        {status, ip, err} = DnsWorker.get_status(updated_profile.id)
        if status == :running do
          Hermit.Vpn.DnsSupervisor.stop_dns(updated_profile.id)
          Hermit.Vpn.DnsSupervisor.start_dns(updated_profile.id)
        end

        # Reload list of dns profiles
        dns_profiles = Hermit.Repo.all(from(d in Hermit.Vpn.DnsConfig, order_by: d.name))

        {:noreply,
         socket
         |> assign(profile: updated_profile)
         |> assign(dns_config: updated_dns_config)
         |> assign(dns_profiles: dns_profiles)
         |> assign(dns_status: status)
         |> assign(dns_ip: ip)
         |> assign(dns_error: err)
         |> put_flash(:info, "Linked DNS Profile updated successfully.")}

      {:error, changeset} ->
        error_msg =
          Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} ->
            "#{field} #{msg}"
          end)

        {:noreply, put_flash(socket, :error, "Failed to change DNS profile: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("save_upstream_dns", %{"upstream_dns" => upstream}, socket) do
    profile_id = socket.assigns.id

    case DnsConfig.update_for_profile(profile_id, %{upstream_dns: String.trim(upstream)}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Upstream DNS servers updated.")}

      {:error, changeset} ->
        error_msg =
          case changeset.errors[:upstream_dns] do
            {msg, _} -> msg
            _ -> "Invalid IP addresses provided"
          end

        {:noreply, put_flash(socket, :error, "Failed to update Upstream DNS: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("custom_rule_action_changed", %{"action" => action}, socket) do
    {:noreply, assign(socket, custom_rule_action: action)}
  end

  @impl true
  def handle_event("add_custom_rule", %{"domain" => domain, "action" => action} = params, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    custom_rules = config.custom_rules || []

    domain = String.trim(domain) |> String.downcase()
    value = if action == "redirect", do: String.trim(Map.get(params, "value", "")), else: nil

    cond do
      domain == "" ->
        {:noreply, put_flash(socket, :error, "Domain cannot be empty.")}

      action == "redirect" and (is_nil(value) or value == "") ->
        {:noreply, put_flash(socket, :error, "Redirect IP value cannot be empty.")}

      true ->
        new_rule = %{"domain" => domain, "action" => action, "value" => value}
        updated_rules = Enum.reject(custom_rules, &(&1["domain"] == domain)) ++ [new_rule]

        case DnsConfig.update_for_profile(profile_id, %{custom_rules: updated_rules}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(dns_config: updated)
             |> put_flash(:info, "Custom rule for #{domain} added.")}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, "Failed to save rule. Ensure IP address is valid.")}
        end
    end
  end

  @impl true
  def handle_event("delete_custom_rule", %{"domain" => domain}, socket) do
    profile_id = socket.assigns.id
    config = socket.assigns.dns_config
    custom_rules = config.custom_rules || []
    updated_rules = Enum.reject(custom_rules, &(&1["domain"] == domain))

    case DnsConfig.update_for_profile(profile_id, %{custom_rules: updated_rules}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Custom rule for #{domain} deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete rule.")}
    end
  end

  @impl true
  def handle_event("delete_domain", %{"pair-id" => pair_id_or_tag, "domain" => domain}, socket) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id_or_tag) do
      nil ->
        if String.starts_with?(pair_id_or_tag, "tag:") do
          profile = socket.assigns.profile

          case Hermit.Vpn.Inbound.Tailscale.get_app_connectors(profile) do
            {:ok, list} ->
              connector =
                Enum.find(list, fn conn -> pair_id_or_tag in Map.get(conn, "connectors", []) end)

              if connector do
                existing_domains = Map.get(connector, "domains", [])
                updated_domains = Enum.reject(existing_domains, &(&1 == domain))

                case Hermit.Vpn.Inbound.Tailscale.update_profile_connector_acl(
                       profile,
                       pair_id_or_tag,
                       updated_domains
                     ) do
                  {:ok, _} ->
                    socket = reload_routing_tab(socket)

                    {:noreply,
                     put_flash(
                       socket,
                       :info,
                       "Domain #{domain} removed from external node #{pair_id_or_tag}. ACL updated."
                     )}

                  {:error, reason} ->
                    {:noreply,
                     put_flash(
                       socket,
                       :error,
                       "Failed to update Tailscale ACL: #{inspect(reason)}"
                     )}
                end
              else
                {:noreply, put_flash(socket, :error, "Connector not found in Tailscale ACL.")}
              end

            _ ->
              {:noreply, put_flash(socket, :error, "Failed to retrieve Tailscale ACL.")}
          end
        else
          {:noreply, put_flash(socket, :error, "Tunnel not found.")}
        end

      pair ->
        inbound_config = pair.inbound_config || %{}

        domains_str =
          Map.get(inbound_config, "advertise_connector_domains") ||
            Map.get(inbound_config, :advertise_connector_domains) || ""

        domains_list =
          domains_str
          |> String.split([",", "\n"])
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        updated_domains_list = Enum.reject(domains_list, &(&1 == domain))
        updated_domains_str = Enum.join(updated_domains_list, "\n")

        updated_inbound_config =
          Map.put(inbound_config, "advertise_connector_domains", updated_domains_str)

        case Hermit.Vpn.PairWorker.update_inbound_config(pair_id_or_tag, updated_inbound_config) do
          {:ok, _updated_pair} ->
            socket = reload_routing_tab(socket)

            {:noreply,
             socket
             |> put_flash(:info, "Domain #{domain} removed. Applying changes to Tailscale ACL...")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to remove domain: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    profile = socket.assigns.profile

    if profile && profile.type == "tailscale" do
      {status, ip, err} = DnsWorker.get_status(profile.id)
      {:noreply, assign(socket, dns_status: status, dns_ip: ip, dns_error: err)}
    else
      {:noreply, socket}
    end
  end

  defp reload_routing_tab(socket) do
    profile = socket.assigns.profile

    pairs_db =
      from(p in Hermit.Vpn.VpnPair,
        where: p.inbound_profile_id == ^profile.id
      )
      |> Hermit.Repo.all()
      |> Hermit.Repo.preload(:inbound_profile)

    hermit_tags =
      Enum.map(pairs_db, fn p ->
        p.inbound_config["advertise_connector_tag"] ||
          "tag:connector-#{String.replace(p.pair_id, "_", "-")}"
      end)
      |> MapSet.new()

    external_connectors =
      case Hermit.Vpn.Inbound.Tailscale.get_app_connectors(profile) do
        {:ok, list} ->
          list
          |> Enum.filter(fn conn ->
            tag = Enum.at(conn["connectors"] || [], 0)
            tag && not MapSet.member?(hermit_tags, tag)
          end)
          |> Enum.map(fn conn ->
            tag = Enum.at(conn["connectors"], 0)

            %{
              id: tag,
              name: conn["name"] || tag,
              is_external: true,
              inbound_config: %{
                "advertise_connector" => true,
                "advertise_connector_tag" => tag,
                "advertise_connector_domains" => Enum.join(conn["domains"] || [], "\n"),
                "advertise_routes" => ""
              },
              wg_status: :external,
              ts_status: :external
            }
          end)

        _ ->
          []
      end

    hermit_pairs =
      Enum.map(pairs_db, fn pair ->
        case Hermit.Vpn.PairWorker.get_state(pair.pair_id) do
          {:error, _} ->
            %{
              id: pair.pair_id,
              is_external: false,
              wg_status: String.to_atom(pair.wg_status || "stopped"),
              ts_status: String.to_atom(pair.ts_status || "stopped"),
              inbound_config: pair.inbound_config || %{}
            }

          worker_state ->
            %{
              id: worker_state.id,
              is_external: false,
              wg_status: worker_state.wg_status,
              ts_status: worker_state.ts_status,
              inbound_config: worker_state.inbound_config || %{}
            }
        end
      end)

    assign(socket, vpn_pairs: hermit_pairs ++ external_connectors)
  end

  defp parse_domains(domains_str) do
    if is_binary(domains_str) do
      domains_str
      |> String.split([",", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
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
