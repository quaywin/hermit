defmodule HermitWeb.DashboardLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.Form
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.DnsWorker
  alias Hermit.Vpn.DnsLogReceiver

  @topic "vpn_pairs"
  @dns_topic "dns_logs:global"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic)
      Phoenix.PubSub.subscribe(Hermit.PubSub, @dns_topic)
    end

    pairs = PairWorker.list_pairs()
    inbound_profiles = Hermit.Repo.all(Hermit.Vpn.InboundProfile)
    outbound_profiles = Hermit.Repo.all(Hermit.Vpn.OutboundProfile)
    dns_config = DnsConfig.get_global()
    {dns_status, dns_ip, dns_error} = DnsWorker.get_status()

    recent_logs =
      DnsLogReceiver.get_recent_logs("global")
      |> Enum.map(fn log ->
        Map.put(log, :id, "#{log["timestamp"] || System.system_time(:second)}-#{System.unique_integer([:monotonic])}")
      end)

    {:ok,
     socket
     |> stream(:vpn_pairs, pairs)
     |> stream(:dns_logs, recent_logs, limit: 150)
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(outbound_profiles: outbound_profiles)
     |> assign(active_tab: :tunnels)
     |> assign(editing_inbound_profile: nil)
     |> assign(editing_inbound_form: nil)
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)
     # Global DNS assigns
     |> assign(dns_config: dns_config)
     |> assign(dns_status: dns_status)
     |> assign(dns_ip: dns_ip)
     |> assign(dns_error: dns_error)
     |> assign(custom_rule_action: "block")
     |> assign_form()
     |> assign_inbound_form()
     |> assign_outbound_form()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_atom(tab))}
  end

  # --- Global DNS Controls ---

  @impl true
  def handle_event("toggle_dns_enabled", _params, socket) do
    config = socket.assigns.dns_config
    enabled = not config.enabled

    case DnsConfig.update_global(%{enabled: enabled}) do
      {:ok, updated} ->
        # Sync the worker
        {:ok, _} = DnsWorker.sync_state()
        {status, ip, err} = DnsWorker.get_status()

        {:noreply,
         socket
         |> assign(dns_config: updated, dns_status: status, dns_ip: ip, dns_error: err)
         |> put_flash(:info, "Global DNS Filtering #{if enabled, do: "enabled", else: "disabled"}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle DNS filtering: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_block_ads", _params, socket) do
    config = socket.assigns.dns_config
    block_ads = not config.block_ads

    case DnsConfig.update_global(%{block_ads: block_ads}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Ads/Trackers blocking #{if block_ads, do: "enabled", else: "disabled"}!")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update ads blocking: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_block_adult", _params, socket) do
    config = socket.assigns.dns_config
    block_adult = not config.block_adult

    case DnsConfig.update_global(%{block_adult: block_adult}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Adult content blocking #{if block_adult, do: "enabled", else: "disabled"}!")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update adult content blocking: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_override_dns", _params, socket) do
    config = socket.assigns.dns_config
    override = not config.tailscale_override_dns

    case DnsConfig.update_global(%{tailscale_override_dns: override}) do
      {:ok, updated} ->
        {:ok, _} = DnsWorker.sync_state()
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Tailscale DNS integration #{if override, do: "enabled", else: "disabled"}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update Tailscale DNS integration.")}
    end
  end

  @impl true
  def handle_event("save_upstream_dns", %{"upstream_dns" => upstream}, socket) do
    case DnsConfig.update_global(%{upstream_dns: String.trim(upstream)}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(dns_config: updated)
         |> put_flash(:info, "Global Upstream DNS servers updated.")}

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
        # Remove existing rule for domain if any
        updated_rules = Enum.reject(custom_rules, &(&1["domain"] == domain)) ++ [new_rule]

        case DnsConfig.update_global(%{custom_rules: updated_rules}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(dns_config: updated)
             |> put_flash(:info, "Custom rule for #{domain} added.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save rule. Ensure IP address is valid.")}
        end
    end
  end

  @impl true
  def handle_event("delete_custom_rule", %{"domain" => domain}, socket) do
    config = socket.assigns.dns_config
    custom_rules = config.custom_rules || []
    updated_rules = Enum.reject(custom_rules, &(&1["domain"] == domain))

    case DnsConfig.update_global(%{custom_rules: updated_rules}) do
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
  def handle_event("clear_dns_logs", _params, socket) do
    DnsLogReceiver.clear_logs("global")
    {:noreply, stream(socket, :dns_logs, [], reset: true)}
  end

  # --- VPN Pair & Profile Management ---

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

  # --- PubSub Handling ---

  @impl true
  def handle_info({:vpn_pair_updated, state}, socket) do
    {:noreply, stream_insert(socket, :vpn_pairs, state)}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, id}, socket) do
    {:noreply, stream_delete(socket, :vpn_pairs, %{id: id})}
  end

  @impl true
  def handle_info({:dns_log, log}, socket) do
    # Add unique ID for streaming
    log_with_id = Map.put(log, :id, "#{log["timestamp"] || System.system_time(:second)}-#{System.unique_integer([:monotonic])}")
    {:noreply, stream_insert(socket, :dns_logs, log_with_id, at: 0, limit: 150)}
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

  def format_dns_time(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> "-"
    end
  end
end
