defmodule HermitWeb.TunnelDetailLive do
  use HermitWeb, :live_view
  import HermitWeb.TunnelComponents
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor

  @topic "vpn_pairs"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic)
      Phoenix.PubSub.subscribe(Hermit.PubSub, "smart_routes")
      Registry.register(Hermit.Vpn.Registry, {:ui_session, self()}, :active)
      :timer.send_interval(1000, self(), :tick)
    end

    case PairWorker.get_state(id) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Tunnel '#{id}' not found.")
         |> push_navigate(to: ~p"/")}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Tunnel '#{id}' unavailable: #{inspect(reason)}")
         |> push_navigate(to: ~p"/")}

      pair ->
        {:ok,
         socket
         |> assign(id: id)
         |> assign(uptime: format_uptime(pair.started_at))
         |> assign(show_edit_modal: false)
         |> assign(form: nil)
         |> assign(active_tab: :overview)
         |> assign_pair(pair)}
    end
  end

  @impl true
  def handle_event("start_tunnel", _params, socket) do
    id = socket.assigns.id
    vpn_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, id)

    case Hermit.Vpn.VpnPair.check_outbound_conflict(vpn_pair.outbound_profile_id, id) do
      {:error, conflicting_id} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to start Tunnel: Outbound profile is already in use by active tunnel '#{conflicting_id}'."
         )}

      :ok ->
        case PairWorker.resume_pair(id) do
          {:ok, pair} ->
            {:noreply,
             socket
             |> assign_pair(pair)
             |> assign(uptime: format_uptime(pair.started_at))
             |> put_flash(:info, "Tunnel starting...")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to start Tunnel: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("stop_tunnel", _params, socket) do
    id = socket.assigns.id

    case PairWorker.pause_pair(id) do
      {:ok, pair} ->
        {:noreply,
         socket
         |> assign_pair(pair)
         |> assign(uptime: format_uptime(pair.started_at))
         |> put_flash(:info, "Tunnel stopped.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop Tunnel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("restart_tunnel", _params, socket) do
    id = socket.assigns.id
    vpn_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, id)

    case Hermit.Vpn.VpnPair.check_outbound_conflict(vpn_pair.outbound_profile_id, id) do
      {:error, conflicting_id} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to restart Tunnel: Outbound profile is already in use by active tunnel '#{conflicting_id}'."
         )}

      :ok ->
        case PairWorker.restart_pair(id) do
          {:ok, pair} ->
            {:noreply,
             socket
             |> assign_pair(pair)
             |> assign(uptime: format_uptime(pair.started_at))
             |> put_flash(:info, "Tunnel restarting...")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to restart Tunnel: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("toggle_exit_node", _params, socket) do
    id = socket.assigns.id
    pair = socket.assigns.pair
    inbound_config = pair.inbound_config || %{}

    current_val =
      case Map.get(inbound_config, "advertise_exit_node") do
        false -> false
        "false" -> false
        nil -> true
        _ -> true
      end

    new_val = not current_val
    new_config = Map.put(inbound_config, "advertise_exit_node", new_val)

    case PairWorker.update_inbound_config(id, new_config) do
      {:ok, updated_pair} ->
        {:noreply,
         socket
         |> assign_pair(updated_pair)
         |> put_flash(
           :info,
           "Exit node routing #{if new_val, do: "enabled", else: "disabled"}. Applying changes dynamically..."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle exit node: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_use_tailscale_dns", _params, socket) do
    new_use_default = not socket.assigns.use_tailscale_dns

    if new_use_default do
      id = socket.assigns.id
      pair = socket.assigns.pair
      inbound_config = pair.inbound_config || %{}

      new_config =
        inbound_config
        |> Map.put("dns_mode", "default")
        |> Map.put("dns_resolvers", "")

      case PairWorker.update_inbound_config(id, new_config) do
        {:ok, updated_pair} ->
          {:noreply,
           socket
           |> assign(use_tailscale_dns: true)
           |> assign_pair(updated_pair)
           |> put_flash(:info, "Tailscale network settings updated. Applying dynamically...")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Failed to update DNS settings: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, use_tailscale_dns: false)}
    end
  end

  @impl true
  def handle_event("toggle_wg_use_tailscale_dns", _params, socket) do
    id = socket.assigns.id
    pair = socket.assigns.pair
    outbound_config = pair.outbound_config || %{}

    current_val =
      case Map.get(outbound_config, "use_tailscale_dns") do
        true -> true
        "true" -> true
        _ -> false
      end

    new_val = not current_val
    new_config = Map.put(outbound_config, "use_tailscale_dns", new_val)

    case PairWorker.update_outbound_config(id, new_config) do
      {:ok, updated_pair} ->
        {:noreply,
         socket
         |> assign_pair(updated_pair)
         |> put_flash(
           :info,
           "WireGuard DNS updated. #{if new_val, do: "Using Tailscale DNS.", else: "Using Configured DNS."} Applying changes dynamically..."
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to toggle WireGuard DNS settings: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_routes_dns_settings", params, socket) do
    id = socket.assigns.id
    pair = socket.assigns.pair
    inbound_config = pair.inbound_config || %{}

    use_tailscale_dns =
      case Map.get(params, "use_tailscale_dns") do
        "true" ->
          true

        "false" ->
          false

        nil ->
          dns_res = Map.get(params, "dns_resolvers")

          if is_binary(dns_res) and String.trim(dns_res) != "" do
            false
          else
            socket.assigns.use_tailscale_dns
          end
      end

    {dns_mode, dns_resolvers} =
      if use_tailscale_dns do
        {"default", ""}
      else
        dns_val = Map.get(params, "dns_resolvers", "") |> String.trim()
        {"custom", dns_val}
      end

    routing_targets =
      (Map.get(params, "routing_targets") || Map.get(params, "advertise_routes") || "")
      |> String.trim()

    parsed_routing = Hermit.Vpn.RoutingParser.parse(routing_targets)
    advertise_routes = Hermit.Vpn.RoutingParser.format_subnets(parsed_routing.subnets)

    new_config =
      inbound_config
      |> Map.put("dns_mode", dns_mode)
      |> Map.put("dns_resolvers", dns_resolvers)
      |> Map.put("routing_targets", routing_targets)
      |> Map.put("advertise_routes", advertise_routes)
      |> Map.put("routed_domains", parsed_routing.domains)

    case PairWorker.update_inbound_config(id, new_config) do
      {:ok, updated_pair} ->
        {:noreply,
         socket
         |> assign_pair(updated_pair)
         |> put_flash(:info, "Tailscale network settings updated. Applying dynamically...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update settings: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("edit_wg_config", _params, socket) do
    id = socket.assigns.id

    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tunnel not found in database.")}

      vpn_pair ->
        vpn_pair = Hermit.Repo.preload(vpn_pair, :outbound_profile)

        wg_config =
          (vpn_pair.outbound_config && vpn_pair.outbound_config["wg_config"]) ||
            (vpn_pair.outbound_profile && vpn_pair.outbound_profile.config["wg_config"])

        vpn_pair = %{vpn_pair | wg_config: wg_config}
        changeset = Hermit.Vpn.VpnPair.changeset(vpn_pair, %{})

        {:noreply,
         socket
         |> assign(show_edit_modal: true)
         |> assign(form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("close_edit_modal", _params, socket) do
    {:noreply, assign(socket, show_edit_modal: false)}
  end

  @impl true
  def handle_event("validate_wg_config", %{"vpn_pair" => params}, socket) do
    id = socket.assigns.id
    vpn_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, id)
    vpn_pair = Hermit.Repo.preload(vpn_pair, :outbound_profile)

    wg_config =
      (vpn_pair.outbound_config && vpn_pair.outbound_config["wg_config"]) ||
        (vpn_pair.outbound_profile && vpn_pair.outbound_profile.config["wg_config"])

    vpn_pair = %{vpn_pair | wg_config: wg_config}

    changeset =
      vpn_pair
      |> Hermit.Vpn.VpnPair.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_wg_config", %{"vpn_pair" => %{"wg_config" => new_wg_config}}, socket) do
    id = socket.assigns.id

    case PairWorker.update_wg_config(id, new_wg_config) do
      {:ok, _status} ->
        case PairWorker.get_state(id) do
          {:error, _} ->
            {:noreply,
             socket
             |> assign(show_edit_modal: false)
             |> put_flash(:info, "WireGuard configuration updated successfully.")}

          pair ->
            {:noreply,
             socket
             |> assign_pair(pair)
             |> assign(show_edit_modal: false)
             |> put_flash(:info, "WireGuard configuration updated successfully.")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to update configuration: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    id = socket.assigns.id

    case DynamicSupervisor.stop_pair(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "VPN Pair '#{id}' deleted.")
         |> push_navigate(to: ~p"/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    active_tab =
      case tab do
        "overview" -> :overview
        _ -> :overview
      end

    {:noreply, assign(socket, active_tab: active_tab)}
  end

  @impl true
  def handle_info({:vpn_pair_updated, pair}, socket) do
    if pair.id == socket.assigns.id do
      current_use_dns = socket.assigns.use_tailscale_dns

      {:noreply,
       socket
       |> assign_pair(pair)
       |> assign(use_tailscale_dns: current_use_dns)
       |> assign(uptime: format_uptime(pair.started_at))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    uptime =
      case socket.assigns[:pair] do
        nil -> "-"
        pair -> format_uptime(pair.started_at)
      end

    {:noreply, assign(socket, uptime: uptime)}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, id}, socket) do
    if id == socket.assigns.id do
      {:noreply,
       socket
       |> put_flash(:info, "Tunnel '#{id}' was deleted.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:smart_routes_updated, _all_pairs}, socket) do
    summary = Hermit.Vpn.SniProxy.routed_summary_for_pair(socket.assigns.id)
    {:noreply, assign(socket, routed_summary: summary)}
  end

  # --- Local Formatting Helpers ---
  defp get_system_dns do
    case File.read("/etc/resolv.conf") do
      {:ok, content} ->
        ips =
          content
          |> String.split(["\n", "\r\n"])
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "nameserver"))
          |> Enum.map(fn line ->
            line
            |> String.trim_leading("nameserver")
            |> String.trim()
          end)
          |> Enum.reject(&(&1 == ""))

        if ips == [] do
          "8.8.8.8, 8.8.4.4"
        else
          Enum.join(ips, ", ")
        end

      _ ->
        "8.8.8.8, 8.8.4.4"
    end
  end

  defp assign_pair(socket, pair) do
    inbound_config = stringify_keys(pair.inbound_config || %{})
    outbound_config = stringify_keys(pair.outbound_config || %{})
    pair = %{pair | inbound_config: inbound_config, outbound_config: outbound_config}

    use_tailscale_dns =
      case Map.get(inbound_config, "dns_mode") do
        "default" ->
          true

        "custom" ->
          false

        nil ->
          dns_res = Map.get(inbound_config, "dns_resolvers")

          if is_binary(dns_res) and String.trim(dns_res) != "" do
            false
          else
            true
          end
      end

    wg_content =
      Map.get(pair, :wg_config_content) || Map.get(pair, :wg_config) ||
        (is_map(pair.outbound_config) &&
           (pair.outbound_config["wg_config"] || pair.outbound_config[:wg_config])) ||
        read_wg_config_from_disk(pair)

    pair_id = Map.get(pair, :pair_id) || Map.get(pair, :id) || socket.assigns[:id]

    routed_summary =
      if is_binary(pair_id),
        do: Hermit.Vpn.SniProxy.routed_summary_for_pair(pair_id),
        else: %{services: [], custom_domains: []}

    socket
    |> assign(pair: pair)
    |> assign(routed_summary: routed_summary)
    |> assign(use_tailscale_dns: use_tailscale_dns)
    |> assign(system_dns: get_system_dns())
    |> assign(wg_info: parse_wg_config(wg_content))
  end

  def parse_wg_config(nil), do: %{}
  def parse_wg_config(""), do: %{}

  def parse_wg_config(content) when is_binary(content) do
    lines = String.split(content, ["\n", "\r\n"])

    {_section, data} =
      Enum.reduce(lines, {nil, %{}}, fn line, {current_section, acc} ->
        line = String.trim(line)

        cond do
          line == "" or String.starts_with?(line, "#") or String.starts_with?(line, ";") ->
            {current_section, acc}

          String.match?(line, ~r/^\[.*\]$/) ->
            sec_name =
              line
              |> String.trim_leading("[")
              |> String.trim_trailing("]")
              |> String.downcase()

            {sec_name, acc}

          current_section != nil and String.contains?(line, "=") ->
            [key, value] = String.split(line, "=", parts: 2)
            key = key |> String.trim() |> String.downcase()
            value = String.trim(value)

            new_acc =
              case {current_section, key} do
                {"interface", "address"} -> Map.put(acc, :interface_address, value)
                {"interface", "listenport"} -> Map.put(acc, :interface_listen_port, value)
                {"interface", "dns"} -> Map.put(acc, :interface_dns, value)
                {"peer", "endpoint"} -> Map.put(acc, :peer_endpoint, value)
                {"peer", "publickey"} -> Map.put(acc, :peer_public_key, value)
                {"peer", "allowedips"} -> Map.put(acc, :peer_allowed_ips, value)
                _ -> acc
              end

            {current_section, new_acc}

          true ->
            {current_section, acc}
        end
      end)

    data
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

  def format_bytes(bytes), do: Hermit.format_bytes(bytes)

  defp read_wg_config_from_disk(pair) do
    path = Map.get(pair, :wg_config_path)

    if is_binary(path) and File.exists?(path) do
      case File.read(path) do
        {:ok, content} when content != "" -> content
        _ -> nil
      end
    else
      nil
    end
  end

  defp stringify_keys(val), do: Hermit.stringify_keys(val)
end
