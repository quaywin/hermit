defmodule HermitWeb.DnsProfileLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsConfig
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)

    # Chọn profile đầu tiên làm mặc định nếu có, hoặc nil
    selected_profile = List.first(dns_profiles)

    # Đăng ký nhận log truy vấn DNS nếu có selected_profile
    if selected_profile do
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_logs_profile:#{selected_profile.id}")
        Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{selected_profile.id}")
      end
    end

    dns_logs = if selected_profile, do: get_recent_logs(selected_profile.id), else: []
    dns_metrics = if selected_profile, do: get_metrics(selected_profile.id, "24h"), else: nil

    {:ok,
     socket
     |> assign(dns_profiles: dns_profiles)
     |> assign(selected_profile: selected_profile)
     |> assign(dns_logs: dns_logs)
     |> assign(dns_metrics: dns_metrics)
     |> assign(time_range: "24h")
     |> assign(show_create_modal: false)
     |> assign(custom_rule_action: "block")
     |> assign(editing_name: false)
     |> assign(pause_logs: false)
     |> assign_create_form()
     |> assign_name_form()}
  end

  @impl true
  def handle_params(%{"id" => id_str}, _uri, socket) do
    id = String.to_integer(id_str)
    profile = Hermit.Repo.get!(DnsConfig, id)

    # Hủy đăng ký PubSub cũ
    if socket.assigns.selected_profile do
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        Phoenix.PubSub.unsubscribe(Hermit.PubSub, "dns_logs_profile:#{socket.assigns.selected_profile.id}")
        Phoenix.PubSub.unsubscribe(Hermit.PubSub, "dns_config_profile:#{socket.assigns.selected_profile.id}")
      end
    end

    # Đăng ký PubSub mới
    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_logs_profile:#{profile.id}")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{profile.id}")
    end

    {:noreply,
     socket
     |> assign(selected_profile: profile)
     |> assign(editing_name: false)
     |> assign(dns_logs: get_recent_logs(profile.id))
     |> assign(dns_metrics: get_metrics(profile.id, socket.assigns[:time_range] || "24h"))
     |> assign_name_form()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_edit_name", _params, socket) do
    {:noreply, assign(socket, editing_name: true)}
  end

  @impl true
  def handle_event("cancel_edit_name", _params, socket) do
    {:noreply, assign(socket, editing_name: false)}
  end

  @impl true
  def handle_event("save_name", %{"dns_config" => %{"name" => name}}, socket) do
    profile = socket.assigns.selected_profile
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Profile name cannot be empty.")}
    else
      case DnsConfig.changeset(profile, %{name: name}) |> Hermit.Repo.update() do
        {:ok, updated} ->
          if :erlang.whereis(Hermit.PubSub) != :undefined do
            Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_config:#{profile.id}", {:dns_config_updated, updated})
          end

          dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)

          {:noreply,
           socket
           |> assign(selected_profile: updated)
           |> assign(dns_profiles: dns_profiles)
           |> assign(editing_name: false)
           |> assign_name_form()
           |> put_flash(:info, "DNS Profile renamed successfully.")}

        {:error, changeset} ->
          {:noreply, assign(socket, name_form: to_form(changeset))}
      end
    end
  end

  @impl true
  def handle_event("toggle_pause_logs", _params, socket) do
    {:noreply, assign(socket, pause_logs: not socket.assigns.pause_logs)}
  end

  @impl true
  def handle_event("select_profile", %{"id" => id_str}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dns?id=#{id_str}")}
  end

  @impl true
  def handle_event("change_time_range", %{"range" => range}, socket) do
    profile = socket.assigns.selected_profile
    metrics = if profile, do: get_metrics(profile.id, range), else: nil
    {:noreply, assign(socket, time_range: range, dns_metrics: metrics)}
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
     |> assign_create_form()}
  end

  @impl true
  def handle_event("validate_create", %{"dns_config" => params}, socket) do
    changeset =
      %DnsConfig{}
      |> DnsConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, create_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_profile", %{"dns_config" => params}, socket) do
    changeset = DnsConfig.changeset(%DnsConfig{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, profile} ->
        dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)

        {:noreply,
         socket
         |> put_flash(:info, "DNS Profile created successfully.")
         |> assign(dns_profiles: dns_profiles)
         |> assign(show_create_modal: false)
         |> assign_create_form()
         |> push_patch(to: ~p"/dns?id=#{profile.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, create_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_profile", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    profile = Hermit.Repo.get!(DnsConfig, id)

    # Kiểm tra xem có Inbound Profile nào đang dùng không
    inbounds = Hermit.Repo.all(from(i in Hermit.Vpn.InboundProfile, where: i.dns_profile_id == ^id))

    if inbounds != [] do
      names = Enum.map_join(inbounds, ", ", & &1.name)
      {:noreply, put_flash(socket, :error, "Cannot delete profile because it is used by inbounds: #{names}")}
    else
      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)
          next_profile = List.first(dns_profiles)

          socket =
            socket
            |> put_flash(:info, "DNS Profile deleted successfully.")
            |> assign(dns_profiles: dns_profiles)

          if next_profile do
            {:noreply, push_patch(socket, to: ~p"/dns?id=#{next_profile.id}")}
          else
            {:noreply, assign(socket, selected_profile: nil, dns_logs: [])}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete DNS Profile.")}
      end
    end
  end

  # Toggles
  @impl true
  def handle_event("toggle_dns_enabled", _params, socket) do
    profile = socket.assigns.selected_profile
    enabled = not profile.enabled
    update_profile(socket, profile, %{enabled: enabled}, "DNS Filtering #{if enabled, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_block_ads", _params, socket) do
    profile = socket.assigns.selected_profile
    block_ads = not profile.block_ads
    update_profile(socket, profile, %{block_ads: block_ads}, "Ads/Trackers blocking #{if block_ads, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_block_adult", _params, socket) do
    profile = socket.assigns.selected_profile
    block_adult = not profile.block_adult
    update_profile(socket, profile, %{block_adult: block_adult}, "Adult content blocking #{if block_adult, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_block_goodbyeads", _params, socket) do
    profile = socket.assigns.selected_profile
    block_goodbyeads = not profile.block_goodbyeads
    update_profile(socket, profile, %{block_goodbyeads: block_goodbyeads}, "GoodbyeAds blocking #{if block_goodbyeads, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_block_ipv6", _params, socket) do
    profile = socket.assigns.selected_profile
    block_ipv6 = not profile.block_ipv6
    update_profile(socket, profile, %{block_ipv6: block_ipv6}, "IPv6 blocking #{if block_ipv6, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_query_logging", _params, socket) do
    profile = socket.assigns.selected_profile
    enable_logging = not profile.enable_query_logging
    update_profile(socket, profile, %{enable_query_logging: enable_logging}, "Query logging #{if enable_logging, do: "enabled", else: "disabled"}!")
  end

  @impl true
  def handle_event("toggle_override_dns", _params, socket) do
    profile = socket.assigns.selected_profile
    override = not profile.tailscale_override_dns
    update_profile(socket, profile, %{tailscale_override_dns: override}, "Tailscale DNS integration #{if override, do: "enabled", else: "disabled"}!")
  end

  # Upstream & Custom Rules
  @impl true
  def handle_event("save_upstream_dns", %{"upstream_dns" => upstream}, socket) do
    profile = socket.assigns.selected_profile
    update_profile(socket, profile, %{upstream_dns: String.trim(upstream)}, "Upstream DNS servers updated.")
  end

  @impl true
  def handle_event("custom_rule_action_changed", %{"action" => action}, socket) do
    {:noreply, assign(socket, custom_rule_action: action)}
  end

  @impl true
  def handle_event("add_custom_rule", %{"domain" => domain, "action" => action} = params, socket) do
    profile = socket.assigns.selected_profile
    custom_rules = profile.custom_rules || []

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
        update_profile(socket, profile, %{custom_rules: updated_rules}, "Custom rule for #{domain} added.")
    end
  end

  @impl true
  def handle_event("delete_custom_rule", %{"domain" => domain}, socket) do
    profile = socket.assigns.selected_profile
    custom_rules = profile.custom_rules || []
    updated_rules = Enum.reject(custom_rules, &(&1["domain"] == domain))
    update_profile(socket, profile, %{custom_rules: updated_rules}, "Custom rule for #{domain} deleted.")
  end

  @impl true
  def handle_event("clear_logs", _params, socket) do
    profile = socket.assigns.selected_profile
    :ets.match_delete(:dns_query_logs, {{profile.id, :_}, :_})
    {:noreply, assign(socket, dns_logs: [], dns_metrics: get_metrics(profile.id, socket.assigns.time_range))}
  end

  # PubSub notifications
  @impl true
  def handle_info({:dns_log, log}, socket) do
    if socket.assigns.selected_profile && socket.assigns.selected_profile.id == socket.assigns.selected_profile.id do
      if socket.assigns.pause_logs do
        {:noreply, socket}
      else
        log_entry = to_log_struct(log)
        updated_logs = [log_entry | socket.assigns.dns_logs] |> Enum.take(50)
        metrics = get_metrics(socket.assigns.selected_profile.id, socket.assigns.time_range)
        {:noreply, assign(socket, dns_logs: updated_logs, dns_metrics: metrics)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:dns_log_added, _profile_id, _log_entry}, socket) do
    # Tương thích ngược với các test case cũ nếu có
    {:noreply, socket}
  end

  @impl true
  def handle_info({:dns_config_updated, updated_config}, socket) do
    if socket.assigns.selected_profile && socket.assigns.selected_profile.id == updated_config.id do
      # Đồng bộ lại state UI
      dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)
      {:noreply, assign(socket, selected_profile: updated_config, dns_profiles: dns_profiles)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helpers
  defp assign_create_form(socket) do
    changeset = DnsConfig.changeset(%DnsConfig{}, %{name: "", custom_rules: []})
    assign(socket, create_form: to_form(changeset))
  end

  defp assign_name_form(socket) do
    profile = socket.assigns.selected_profile
    changeset = if profile, do: DnsConfig.changeset(profile, %{}), else: Ecto.Changeset.change(%DnsConfig{})
    assign(socket, name_form: to_form(changeset))
  end

  defp update_profile(socket, profile, attrs, success_msg) do
    case DnsConfig.changeset(profile, attrs) |> Hermit.Repo.update() do
      {:ok, updated} ->
        # Broadcast configuration update dynamically
        if :erlang.whereis(Hermit.PubSub) != :undefined do
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_config_profile:#{profile.id}", {:dns_config_updated, updated})
        end

        dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name)) |> Hermit.Repo.preload(:inbound_profiles)

        {:noreply,
         socket
         |> assign(selected_profile: updated)
         |> assign(dns_profiles: dns_profiles)
         |> put_flash(:info, success_msg)}

      {:error, changeset} ->
        error_msg =
          Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} ->
            "#{field} #{msg}"
          end)

        {:noreply, put_flash(socket, :error, "Update failed: #{error_msg}")}
    end
  end

  defp get_recent_logs(profile_id) do
    case :ets.whereis(:dns_query_logs) do
      :undefined ->
        []

      _table ->
        # Lấy tối đa 50 log gần nhất của profile này
        # Key structure: {{profile_id, timestamp}, log_entry}
        pattern = {{to_string(profile_id), :_}, :"$1"}

        :ets.select(:dns_query_logs, [{pattern, [], [:"$1"]}])
        # fallback cho key integer hoặc string
        ++ :ets.select(:dns_query_logs, [{{{profile_id, :_}, :"$1"}, [], [:"$1"]}])
        |> Enum.map(&to_log_struct/1)
        |> Enum.sort_by(& &1.timestamp, :desc)
        |> Enum.uniq_by(fn log -> {log.timestamp, log.domain, log.client_ip} end)
        |> Enum.take(50)
    end
  end

  defp to_log_struct(log) do
    %{
      client_ip: Map.get(log, "client_ip") || Map.get(log, :client_ip) || "-",
      client_name: Map.get(log, "client_name") || Map.get(log, :client_name) || "-",
      domain: Map.get(log, "domain") || Map.get(log, :domain) || "-",
      qtype: Map.get(log, "type") || Map.get(log, :qtype) || "A",
      status: Map.get(log, "status") || Map.get(log, :status) || "resolved",
      answer: Map.get(log, "answer") || Map.get(log, :answer) || "-",
      resolver: Map.get(log, "resolver") || Map.get(log, :resolver) || "-",
      timestamp: to_datetime(Map.get(log, "timestamp") || Map.get(log, :timestamp))
    }
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp to_datetime(_), do: DateTime.utc_now()

  defp profile_active?(profile) do
    # check if any associated inbound profile has a running dns_worker
    Enum.any?(profile.inbound_profiles, fn ip ->
      case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, ip.id}) do
        [{_pid, _value}] -> true
        _ -> false
      end
    end)
  end

  defp get_metrics(profile_id, time_range) do
    hours_limit =
      case time_range do
        "1h" -> 1
        "7d" -> 7 * 24
        _ -> 24
      end
    cutoff_time = System.system_time(:second) - hours_limit * 3600

    # Match spec to fetch hourly logs within last cutoff_time
    # Key format: {{profile_id, hour_timestamp}, total, blocked, ipv6, adguard, goodbyeads, adult, custom}
    head = {{profile_id, :"$1"}, :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}
    guard = [{:>=, :"$1", cutoff_time}]
    result = [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]
    pattern = {head, guard, result}

    profile_id_str = to_string(profile_id)
    head_str = {{profile_id_str, :"$1"}, :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}
    pattern_str = {head_str, guard, result}

    records =
      case :ets.whereis(:dns_hourly_metrics) do
        :undefined -> []
        _ ->
          :ets.select(:dns_hourly_metrics, [pattern])
          ++ :ets.select(:dns_hourly_metrics, [pattern_str])
      end

    {total_queries, blocked_queries, ipv6_blocked_count, adguard_blocked, goodbyeads_blocked, adult_blocked, custom_blocked} =
      Enum.reduce(records, {0, 0, 0, 0, 0, 0, 0}, fn {_hour, t, b, i6, adg, gba, adt, cst}, {acc_t, acc_b, acc_i6, acc_adg, acc_gba, acc_adt, acc_cst} ->
        {acc_t + t, acc_b + b, acc_i6 + i6, acc_adg + adg, acc_gba + gba, acc_adt + adt, acc_cst + cst}
      end)

    block_rate = if total_queries > 0, do: Float.round(blocked_queries / total_queries * 100, 1), else: 0.0
    data_saved_kb = blocked_queries * 50
    data_saved_str =
      cond do
        data_saved_kb >= 1024 -> "#{Float.round(data_saved_kb / 1024, 1)} MB"
        true -> "#{data_saved_kb} KB"
      end

    # For Top Blocked trackers, scan the raw logs buffer (limit is 200, which is extremely fast)
    raw_logs = get_raw_logs_from_ets(profile_id)
    top_blocked =
      raw_logs
      |> Enum.filter(fn log -> log.status == "blocked" end)
      |> Enum.frequencies_by(fn log -> log.domain end)
      |> Enum.sort_by(fn {_domain, count} -> count end, :desc)
      |> Enum.take(3)
      |> Enum.map(fn {domain, count} -> %{domain: domain, count: count} end)

    %{
      total: total_queries,
      blocked: blocked_queries,
      block_rate: block_rate,
      data_saved: data_saved_str,
      top_blocked: top_blocked,
      ipv6_blocked_count: ipv6_blocked_count,
      adguard_blocked_count: adguard_blocked,
      goodbyeads_blocked_count: goodbyeads_blocked,
      adult_blocked_count: adult_blocked,
      custom_blocked_count: custom_blocked
    }
  end

  defp get_raw_logs_from_ets(profile_id) do
    raw_logs =
      case :ets.whereis(:dns_query_logs) do
        :undefined -> []
        _ ->
          pattern = {{to_string(profile_id), :_}, :"$1"}
          :ets.select(:dns_query_logs, [{pattern, [], [:"$1"]}])
          ++ :ets.select(:dns_query_logs, [{{{profile_id, :_}, :"$1"}, [], [:"$1"]}])
      end
    Enum.map(raw_logs, &to_log_struct/1)
  end


end
