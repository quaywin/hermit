defmodule HermitWeb.DnsEndpointLive do
  use HermitWeb, :live_view
  import HermitWeb.DnsEndpointComponents
  import Ecto.Query
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.InboundProfile
  alias Hermit.Vpn.DnsWorker
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(3000, self(), :tick)
    end

    endpoints = get_endpoints()
    dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name))

    inbound_profiles =
      Hermit.Repo.all(from(i in InboundProfile, where: i.type == "tailscale", order_by: i.name))

    new_changeset = DnsEndpoint.changeset(%DnsEndpoint{}, %{})

    {:ok,
     socket
     |> assign(endpoints: endpoints)
     |> assign(dns_profiles: dns_profiles)
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(editing_endpoint: nil)
     |> assign(new_form: to_form(new_changeset))
     |> assign(edit_form: nil)
     |> assign(show_new_modal: false)
     |> assign(show_edit_modal: false)
     |> assign(dns_statuses: %{})
     |> assign(dns_sync_statuses: %{})
     |> update_all_dns_statuses()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, update_all_dns_statuses(socket)}
  end

  @impl true
  def handle_info({:dns_config_updated, _updated}, socket) do
    {:noreply, assign(socket, endpoints: get_endpoints())}
  end

  @impl true
  def handle_event("open_new_modal", _params, socket) do
    new_changeset = DnsEndpoint.changeset(%DnsEndpoint{}, %{})

    {:noreply,
     assign(socket,
       show_new_modal: true,
       new_form: to_form(new_changeset)
     )}
  end

  @impl true
  def handle_event("close_new_modal", _params, socket) do
    {:noreply, assign(socket, show_new_modal: false)}
  end

  @impl true
  def handle_event("validate_new", %{"dns_endpoint" => params}, socket) do
    changeset =
      %DnsEndpoint{}
      |> DnsEndpoint.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, new_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_new", %{"dns_endpoint" => params}, socket) do
    changeset = DnsEndpoint.changeset(%DnsEndpoint{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _endpoint} ->
        DnsEndpoint.clear_cache()

        {:noreply,
         socket
         |> put_flash(:info, "DNS Endpoint created successfully.")
         |> assign(show_new_modal: false)
         |> assign(endpoints: get_endpoints())
         |> update_all_dns_statuses()}

      {:error, changeset} ->
        {:noreply, assign(socket, new_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_endpoint", %{"id" => id_str}, socket) do
    endpoint = Hermit.Repo.get!(DnsEndpoint, String.to_integer(id_str))
    changeset = DnsEndpoint.changeset(endpoint, %{})

    {:noreply,
     socket
     |> assign(editing_endpoint: endpoint)
     |> assign(edit_form: to_form(changeset))
     |> assign(show_edit_modal: true)}
  end

  @impl true
  def handle_event("close_edit_modal", _params, socket) do
    {:noreply, assign(socket, show_edit_modal: false, editing_endpoint: nil, edit_form: nil)}
  end

  @impl true
  def handle_event("validate_edit", %{"dns_endpoint" => params}, socket) do
    endpoint = socket.assigns.editing_endpoint

    changeset =
      endpoint
      |> DnsEndpoint.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, edit_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit", %{"dns_endpoint" => params}, socket) do
    endpoint = socket.assigns.editing_endpoint
    changeset = DnsEndpoint.changeset(endpoint, params)

    case Hermit.Repo.update(changeset) do
      {:ok, updated_endpoint} ->
        DnsEndpoint.clear_cache()

        network_changed? = endpoint.inbound_profile_id != updated_endpoint.inbound_profile_id
        {worker_status, _, _} = DnsWorker.get_status(updated_endpoint.id)
        worker_running? = worker_status in [:running, :starting, :error]

        cond do
          network_changed? or worker_running? ->
            Hermit.Vpn.DnsSupervisor.stop_dns(updated_endpoint.id)

            if updated_endpoint.enabled do
              Hermit.Vpn.DnsSupervisor.start_dns(
                updated_endpoint.id,
                updated_endpoint.inbound_profile_id
              )
            end

          true ->
            Hermit.Vpn.DnsSupervisor.restart_dns_server(updated_endpoint.id)
        end

        new_config = Hermit.Vpn.DnsConfig.get_for_endpoint(updated_endpoint.id)

        if :erlang.whereis(Hermit.PubSub) != :undefined do
          Phoenix.PubSub.broadcast(
            Hermit.PubSub,
            "dns_config:#{updated_endpoint.id}",
            {:dns_config_updated, new_config}
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, "DNS Endpoint updated successfully.")
         |> assign(show_edit_modal: false)
         |> assign(editing_endpoint: nil)
         |> assign(edit_form: nil)
         |> assign(endpoints: get_endpoints())
         |> update_all_dns_statuses()}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_endpoint", %{"id" => id_str}, socket) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id) |> Hermit.Repo.preload(:inbound_profile)

    config = DnsConfig.get_for_endpoint(endpoint_id)
    {_, ts_ip, _} = DnsWorker.get_status(endpoint_id)

    if config.tailscale_override_dns do
      Task.start(fn ->
        DnsWorker.clear_tailscale_dns_config(endpoint.inbound_profile, config, ts_ip)
      end)
    end

    if endpoint.inbound_profile do
      Task.start(fn ->
        Hermit.Vpn.Inbound.Tailscale.delete_device_by_hostname(
          "hermit-dns-#{endpoint_id}",
          endpoint.inbound_profile
        )
      end)
    end

    Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)
    Hermit.Repo.delete!(endpoint)
    DnsEndpoint.clear_cache()

    {:noreply,
     socket
     |> put_flash(:info, "DNS Endpoint deleted successfully.")
     |> assign(endpoints: get_endpoints())
     |> update_all_dns_statuses()}
  end

  @impl true
  def handle_event("toggle_endpoint_enabled", %{"id" => id_str}, socket) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id) |> Hermit.Repo.preload(:inbound_profile)
    enabled = not endpoint.enabled

    if enabled and is_nil(endpoint.inbound_profile_id) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Cannot activate endpoint '#{endpoint.name}' without a linked Tailscale Inbound Profile."
       )}
    else
      case endpoint |> DnsEndpoint.changeset(%{enabled: enabled}) |> Hermit.Repo.update() do
        {:ok, updated} ->
          DnsEndpoint.clear_cache()

          if enabled do
            Task.start(fn ->
              case Hermit.Vpn.DnsSupervisor.start_dns(updated.id, updated.inbound_profile_id) do
                {:ok, _} ->
                  :ok

                {:error, reason} ->
                  Logger.error("Failed to start DNS Endpoint: #{inspect(reason)}")
              end
            end)
          else
            config = DnsConfig.get_for_endpoint(endpoint_id)
            {_, ts_ip, _} = DnsWorker.get_status(endpoint_id)

            if config.tailscale_override_dns do
              Task.start(fn ->
                DnsWorker.clear_tailscale_dns_config(endpoint.inbound_profile, config, ts_ip)
              end)
            end

            DnsConfig.update_for_endpoint(endpoint_id, %{tailscale_override_dns: false})

            Task.start(fn ->
              Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)
            end)
          end

          {:noreply,
           socket
           |> put_flash(
             :info,
             "DNS Endpoint #{if enabled, do: "activated", else: "deactivated"}."
           )
           |> assign(endpoints: get_endpoints())
           |> update_all_dns_statuses()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle Endpoint status.")}
      end
    end
  end

  @impl true
  def handle_event("reconnect_node", %{"id" => id_str}, socket) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)

    Task.start(fn ->
      Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)

      case Hermit.Vpn.DnsSupervisor.start_dns(endpoint_id, endpoint.inbound_profile_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Failed to reconnect DNS Node: #{inspect(reason)}")
      end
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Reconnecting DNS Node...")
     |> update_all_dns_statuses()}
  end

  @impl true
  def handle_event("toggle_override_dns", %{"id" => id_str}, socket) do
    endpoint_id = String.to_integer(id_str)
    {status, _, _} = DnsWorker.get_status(endpoint_id)

    if status != :running do
      {:noreply,
       put_flash(socket, :error, "Cannot toggle Override DNS when DNS Node is not running.")}
    else
      config = DnsConfig.get_for_endpoint(endpoint_id)
      override = not config.tailscale_override_dns

      case DnsConfig.update_for_endpoint(endpoint_id, %{tailscale_override_dns: override}) do
        {:ok, _} ->
          DnsWorker.sync_state(endpoint_id)

          endpoint = Hermit.Repo.get(DnsEndpoint, endpoint_id)

          profile =
            endpoint && endpoint.inbound_profile_id &&
              Hermit.Repo.get(Hermit.Vpn.InboundProfile, endpoint.inbound_profile_id)

          profile_config = (profile && profile.config) || %{}

          auth_key =
            Map.get(profile_config, "ts_auth_key") ||
              Map.get(profile_config, :ts_auth_key) ||
              System.get_env("TAILSCALE_AUTH_KEY") ||
              System.get_env("TS_AUTHKEY") ||
              ""

          flash_msg =
            cond do
              override and String.starts_with?(String.trim(auth_key), "tskey-auth-") ->
                "Tailscale DNS Override enabled locally, but note: pre-auth keys (tskey-auth-) cannot auto-update Tailscale DNS via API. Please use an OAuth key (tskey-client-) for automatic sync, or configure Tailscale Admin Console manually."

              override ->
                "Tailscale DNS Override enabled. Syncing with Tailscale..."

              true ->
                "Tailscale DNS Override disabled. Syncing with Tailscale..."
            end

          {:noreply,
           socket
           |> put_flash(:info, flash_msg)
           |> assign(endpoints: get_endpoints())
           |> update_all_dns_statuses()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle DNS override.")}
      end
    end
  end

  @impl true
  def handle_event(
        "select_tailscale_dns_mode",
        %{"endpoint_id" => id_str, "tailscale_dns_mode" => new_mode},
        socket
      )
      when new_mode in ["split", "global"] do
    endpoint_id = String.to_integer(id_str)
    {status, _, _} = DnsWorker.get_status(endpoint_id)

    if status != :running do
      {:noreply,
       put_flash(socket, :error, "Cannot switch Tailscale DNS mode when DNS Node is not running.")}
    else
      config = DnsConfig.get_for_endpoint(endpoint_id)
      current_mode = config.tailscale_dns_mode || "split"

      if new_mode == current_mode do
        {:noreply, socket}
      else
        case DnsConfig.update_for_endpoint(endpoint_id, %{tailscale_dns_mode: new_mode}) do
          {:ok, _} ->
            DnsWorker.sync_state(endpoint_id)

            flash_msg =
              cond do
                new_mode == "global" ->
                  "Switched to Global DNS mode (all traffic via Hermit with full logs). Syncing with Tailscale..."

                match?(
                  {:fallback_global, _},
                  Hermit.Dns.Providers.tailscale_global_resolvers(config.upstream_dns)
                ) ->
                  "Split DNS mode saved, but your custom DoH upstream automatically falls back to Global DNS on Tailscale."

                true ->
                  "Switched to Split DNS mode (direct upstream + Hermit Smart DNS). Syncing with Tailscale..."
              end

            {:noreply,
             socket
             |> put_flash(:info, flash_msg)
             |> assign(endpoints: get_endpoints())
             |> update_all_dns_statuses()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to switch Tailscale DNS mode.")}
        end
      end
    end
  end

  def handle_event("select_tailscale_dns_mode", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "quick_select_dns_profile",
        %{"endpoint_id" => id_str, "dns_profile_id" => dns_profile_id_str},
        socket
      ) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)

    dns_profile_id =
      if dns_profile_id_str == "", do: nil, else: String.to_integer(dns_profile_id_str)

    if dns_profile_id == endpoint.dns_profile_id do
      {:noreply, socket}
    else
      case endpoint
           |> DnsEndpoint.changeset(%{dns_profile_id: dns_profile_id})
           |> Hermit.Repo.update() do
        {:ok, updated_endpoint} ->
          DnsEndpoint.clear_cache()
          Hermit.Vpn.DnsSupervisor.restart_dns_server(endpoint_id)
          DnsWorker.sync_state(endpoint_id)

          new_config = Hermit.Vpn.DnsConfig.get_for_endpoint(endpoint_id)

          if :erlang.whereis(Hermit.PubSub) != :undefined do
            Phoenix.PubSub.broadcast(
              Hermit.PubSub,
              "dns_config:#{endpoint_id}",
              {:dns_config_updated, new_config}
            )
          end

          {:noreply,
           socket
           |> put_flash(:info, "DNS Profile for '#{updated_endpoint.name}' updated successfully.")
           |> assign(endpoints: get_endpoints())
           |> update_all_dns_statuses()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update DNS profile.")}
      end
    end
  end

  defp get_endpoints do
    DnsEndpoint
    |> Hermit.Repo.all()
    |> Hermit.Repo.preload([:dns_profile, :inbound_profile])
  end

  defp update_all_dns_statuses(socket) do
    {statuses, sync_statuses} =
      Enum.reduce(socket.assigns.endpoints, {%{}, %{}}, fn endpoint, {st_acc, sync_acc} ->
        {status_info, sync_info} =
          if endpoint.inbound_profile_id do
            {DnsWorker.get_status(endpoint.id), DnsWorker.get_dns_sync_status(endpoint.id)}
          else
            {{:stopped, nil, nil}, :idle}
          end

        {Map.put(st_acc, endpoint.id, status_info), Map.put(sync_acc, endpoint.id, sync_info)}
      end)

    assign(socket, dns_statuses: statuses, dns_sync_statuses: sync_statuses)
  end
end
