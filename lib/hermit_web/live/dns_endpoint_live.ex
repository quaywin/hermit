defmodule HermitWeb.DnsEndpointLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.InboundProfile
  alias Hermit.Vpn.DnsWorker
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Đăng ký nhận tin nhắn status polling
      :timer.send_interval(1000, self(), :tick)
    end

    endpoints = get_endpoints()
    dns_profiles = Hermit.Repo.all(from(d in DnsConfig, order_by: d.name))

    inbound_profiles =
      Hermit.Repo.all(from(i in InboundProfile, where: i.type == "tailscale", order_by: i.name))

    # Form tạo Endpoint mới
    new_changeset = DnsEndpoint.changeset(%DnsEndpoint{}, %{})

    {:ok,
     socket
     |> assign(endpoints: endpoints)
     |> assign(dns_profiles: dns_profiles)
     |> assign(inbound_profiles: inbound_profiles)
     |> assign(selected_endpoint: nil)
     |> assign(editing_endpoint: nil)
     |> assign(new_form: to_form(new_changeset))
     |> assign(edit_form: nil)
     |> assign(show_new_modal: false)
     |> assign(show_edit_modal: false)
     # Lưu trữ status của các Tailscale Node
     |> assign(dns_statuses: %{})
     |> update_all_dns_statuses()}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(uri)

    port_suffix =
      if port in [80, 443, nil] do
        ""
      else
        ":#{port}"
      end

    base_url = "#{scheme}://#{host}#{port_suffix}"

    {:noreply, assign(socket, base_url: base_url)}
  end

  @impl true
  def handle_info(:tick, socket) do
    # Cập nhật trạng thái của các DNS node định kỳ mỗi giây
    {:noreply, update_all_dns_statuses(socket)}
  end

  @impl true
  def handle_info({:dns_config_updated, _updated}, socket) do
    {:noreply, assign(socket, endpoints: get_endpoints())}
  end

  @impl true
  def handle_event("open_new_modal", _params, socket) do
    new_changeset = DnsEndpoint.changeset(%DnsEndpoint{}, %{})
    {:noreply, assign(socket, show_new_modal: true, new_form: to_form(new_changeset))}
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

        # Reboot DNS node if it was running with old config
        {status, _, _} = DnsWorker.get_status(updated_endpoint.id)

        if status == :running do
          Hermit.Vpn.DnsSupervisor.stop_dns(updated_endpoint.id)

          if updated_endpoint.enabled do
            Hermit.Vpn.DnsSupervisor.start_dns(
              updated_endpoint.id,
              updated_endpoint.inbound_profile_id
            )
          end
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
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)

    # Dừng DNS node và giải phóng cấu hình Tailscale DNS trước khi xóa
    config = DnsConfig.get_for_endpoint(endpoint_id)

    if config && config.tailscale_override_dns do
      Task.start(fn -> DnsWorker.clear_tailscale_dns_config(config) end)
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
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)
    enabled = not endpoint.enabled

    case endpoint |> DnsEndpoint.changeset(%{enabled: enabled}) |> Hermit.Repo.update() do
      {:ok, updated} ->
        DnsEndpoint.clear_cache()

        if enabled do
          Task.start(fn ->
            case Hermit.Vpn.DnsSupervisor.start_dns(updated.id, updated.inbound_profile_id) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.error("Failed to start DNS Endpoint: #{inspect(reason)}")
            end
          end)
        else
          config = DnsConfig.get_for_endpoint(endpoint_id)

          if config && config.tailscale_override_dns do
            Task.start(fn -> DnsWorker.clear_tailscale_dns_config(config) end)
          end

          # Cập nhật DB config tắt luôn override
          if config do
            DnsConfig.update_for_endpoint(endpoint_id, %{tailscale_override_dns: false})
          end

          Task.start(fn ->
            Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)
          end)
        end

        {:noreply,
         socket
         |> put_flash(:info, "DNS Endpoint #{if enabled, do: "activated", else: "deactivated"}.")
         |> assign(endpoints: get_endpoints())
         |> update_all_dns_statuses()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle Endpoint status.")}
    end
  end

  @impl true
  def handle_event("reconnect_node", %{"id" => id_str}, socket) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)

    Task.start(fn ->
      # Stop existing DNS worker to clean up previous run
      Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)

      # Start DNS components
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
          # DnsWorker sync_state will automatically trigger configuration update asynchronously
          DnsWorker.sync_state(endpoint_id)

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Tailscale DNS Override #{if override, do: "enabled", else: "disabled"}."
           )
           |> assign(endpoints: get_endpoints())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle DNS override.")}
      end
    end
  end

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

    case endpoint
         |> DnsEndpoint.changeset(%{dns_profile_id: dns_profile_id})
         |> Hermit.Repo.update() do
      {:ok, updated_endpoint} ->
        DnsEndpoint.clear_cache()

        # Restart DNS server with new profile if it's currently running
        {status, _, _} = DnsWorker.get_status(endpoint_id)

        if status == :running do
          Hermit.Vpn.DnsSupervisor.restart_dns_server(endpoint_id)
        end

        {:noreply,
         socket
         |> put_flash(:info, "DNS Profile for '#{updated_endpoint.name}' updated successfully.")
         |> assign(endpoints: get_endpoints())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update DNS profile.")}
    end
  end

  @impl true
  def handle_event(
        "quick_select_inbound_profile",
        %{"endpoint_id" => id_str, "inbound_profile_id" => inbound_profile_id_str},
        socket
      ) do
    endpoint_id = String.to_integer(id_str)
    endpoint = Hermit.Repo.get!(DnsEndpoint, endpoint_id)

    inbound_profile_id =
      if inbound_profile_id_str == "", do: nil, else: String.to_integer(inbound_profile_id_str)

    # Nếu đang chạy node cũ, ta tự động dừng nó trước khi chuyển đổi profile mạng
    {status, _, _} = DnsWorker.get_status(endpoint_id)

    if status in [:running, :starting] do
      # Xóa override config cũ nếu có
      config = DnsConfig.get_for_endpoint(endpoint_id)

      if config && config.tailscale_override_dns do
        Task.start(fn -> DnsWorker.clear_tailscale_dns_config(config) end)
        DnsConfig.update_for_endpoint(endpoint_id, %{tailscale_override_dns: false})
      end

      Hermit.Vpn.DnsSupervisor.stop_dns(endpoint_id)
    end

    case endpoint
         |> DnsEndpoint.changeset(%{inbound_profile_id: inbound_profile_id, enabled: false})
         |> Hermit.Repo.update() do
      {:ok, updated_endpoint} ->
        DnsEndpoint.clear_cache()

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Network Connection for '#{updated_endpoint.name}' updated. Node is currently stopped."
         )
         |> assign(endpoints: get_endpoints())
         |> update_all_dns_statuses()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update Network Connection.")}
    end
  end

  # Helper functions
  defp get_endpoints do
    DnsEndpoint
    |> Hermit.Repo.all()
    |> Hermit.Repo.preload([:dns_profile, :inbound_profile])
  end

  defp update_all_dns_statuses(socket) do
    statuses =
      Enum.reduce(socket.assigns.endpoints, %{}, fn endpoint, acc ->
        status_info =
          if endpoint.inbound_profile_id do
            # Chỉ lấy status nếu có liên kết inbound profile (Tailscale)
            DnsWorker.get_status(endpoint.id)
          else
            {:stopped, nil, nil}
          end

        Map.put(acc, endpoint.id, status_info)
      end)

    assign(socket, dns_statuses: statuses)
  end
end
