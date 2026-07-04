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
        # Subscription for DNS logs
        if connected?(socket) and profile.type == "tailscale" do
          Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_logs:#{profile.id}")
        end

        dns_config =
          if profile.type == "tailscale", do: DnsConfig.get_for_profile(profile.id), else: nil

        {dns_status, dns_ip, dns_error} =
          if profile.type == "tailscale",
            do: DnsWorker.get_status(profile.id),
            else: {:stopped, nil, nil}

        recent_logs =
          if profile.type == "tailscale" do
            Hermit.Vpn.DnsLogReceiver.get_recent_logs(to_string(profile.id))
            |> Enum.map(fn log ->
              Map.put(
                log,
                :id,
                "#{log["timestamp"] || System.system_time(:second)}-#{System.unique_integer([:monotonic])}"
              )
            end)
          else
            []
          end

        changeset = InboundProfile.changeset(profile, %{})

        {:ok,
         socket
         |> assign(id: id)
         |> assign(profile: profile)
         |> assign(dns_config: dns_config)
         |> assign(dns_status: dns_status)
         |> assign(dns_ip: dns_ip)
         |> assign(dns_error: dns_error)
         |> assign(custom_rule_action: "block")
         |> assign(editing_inbound_form: to_form(changeset))
         |> stream(:dns_logs, recent_logs, reset: true)}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    active_tab =
      case Map.get(params, "tab", "config") do
        "dns" when socket.assigns.profile.type == "tailscale" -> :dns
        _ -> :config
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

    case DnsConfig.update_for_profile(profile_id, %{enabled: enabled}) do
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
    config = socket.assigns.dns_config
    override = not config.tailscale_override_dns

    case DnsConfig.update_for_profile(profile_id, %{tailscale_override_dns: override}) do
      {:ok, updated} ->
        case DnsWorker.sync_state(profile_id) do
          {:ok, _} -> :ok
          {:error, :not_found} -> :ok
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
  def handle_event("clear_dns_logs", _params, socket) do
    profile_id = socket.assigns.id
    Hermit.Vpn.DnsLogReceiver.clear_logs(to_string(profile_id))
    {:noreply, stream(socket, :dns_logs, [], reset: true)}
  end

  @impl true
  def handle_info({:dns_log, log}, socket) do
    log_with_id =
      Map.put(
        log,
        :id,
        "#{log["timestamp"] || System.system_time(:second)}-#{System.unique_integer([:monotonic])}"
      )

    {:noreply, stream_insert(socket, :dns_logs, log_with_id, at: 0, limit: 150)}
  end

  # --- Helpers ---

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

  def format_dns_time(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> "-"
    end
  end
end
