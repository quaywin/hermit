defmodule HermitWeb.ProviderImportLive do
  use HermitWeb, :live_view
  require Logger
  alias Hermit.Vpn.Provider
  alias Hermit.Vpn.Setting

  @impl true
  def mount(_params, _session, socket) do
    # Fetch NordVPN countries asynchronously or on mount.
    send(self(), :load_nord_countries)

    nord_access_token = Setting.get_value("nord_access_token", "")

    {:ok,
     socket
     # General tab control
     |> assign(current_tab: "nordvpn")
     # NordVPN assigns
     |> assign(nord_access_token: nord_access_token)
     |> assign(nord_private_key: "")
     |> assign(nord_address: "10.5.0.2/32")
     |> assign(nord_dns: "10.5.0.1")
     |> assign(nord_countries: [])
     |> assign(nord_cities: [])
     |> assign(selected_nord_city: "")
     |> assign(selected_nord_country: "")
     |> assign(nord_selected_country_name: "")
     |> assign(show_nord_dropdown: false)
     |> assign(nord_servers: [])
     |> assign(best_nord_server_id: nil)
     |> assign(selected_nord_servers: MapSet.new())
     |> assign(nord_prefix: "NordVPN")
     |> assign(nord_limit: 15)
     |> assign(nord_loading: false)
     # Bulk Import assigns
     |> assign(paste_text: "")
     |> assign(paste_name: "Imported WireGuard")
     |> allow_upload(:wg_files,
       accept: :any,
       max_entries: 1,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> assign_saved_configs()}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, current_tab: tab)}
  end

  # --- NordVPN Events ---

  @impl true
  def handle_event("change_nord_fields", params, socket) do
    # Handle normal fields change
    access_token = Map.get(params, "access_token", socket.assigns.nord_access_token)
    prefix = Map.get(params, "prefix", socket.assigns.nord_prefix)
    limit = Map.get(params, "limit", to_string(socket.assigns.nord_limit)) |> String.to_integer()

    {:noreply,
     socket
     |> assign(nord_access_token: access_token)
     |> assign(nord_prefix: prefix)
     |> assign(nord_limit: limit)}
  end

  @impl true
  def handle_event("open_nord_dropdown", _params, socket) do
    {:noreply, assign(socket, show_nord_dropdown: true, nord_country_search: "")}
  end

  @impl true
  def handle_event("close_nord_dropdown", _params, socket) do
    # When user clicks away, if the input is empty or search is active, we restore the selected country name
    current_country =
      Enum.find(socket.assigns.nord_countries, fn c ->
        c.id == socket.assigns.selected_nord_country
      end)

    name = if current_country, do: "#{current_country.name} (#{current_country.code})", else: ""

    {:noreply,
     assign(socket,
       show_nord_dropdown: false,
       nord_selected_country_name: name,
       nord_country_search: ""
     )}
  end

  @impl true
  def handle_event("search_nord_country", %{"value" => query}, socket) do
    {:noreply, assign(socket, nord_country_search: query, nord_selected_country_name: query)}
  end

  @impl true
  def handle_event("select_nord_country_item", %{"id" => country_id}, socket) do
    country_id = String.to_integer(country_id)
    country = Enum.find(socket.assigns.nord_countries, fn c -> c.id == country_id end)
    code = if country, do: country.code, else: "VPN"

    name =
      if country do
        server_cnt_str =
          if country[:server_count] > 0, do: " - #{country.server_count} servers", else: ""

        "#{country.name} (#{country.code})#{server_cnt_str}"
      else
        ""
      end

    cities = if country, do: country[:cities] || [], else: []

    {:noreply,
     socket
     |> assign(selected_nord_country: country_id)
     |> assign(nord_selected_country_name: name)
     |> assign(nord_cities: cities)
     |> assign(selected_nord_city: "")
     |> assign(nord_prefix: "NordVPN - #{code}")
     |> assign(show_nord_dropdown: false)
     |> assign(nord_country_search: "")
     # Clear previously fetched servers
     |> assign(nord_servers: [])
     |> assign(best_nord_server_id: nil)
     |> assign(selected_nord_servers: MapSet.new())}
  end

  @impl true
  def handle_event("select_nord_city", %{"city_id" => city_id_str}, socket) do
    selected_city_id = if city_id_str == "", do: "", else: String.to_integer(city_id_str)

    {:noreply,
     socket
     |> assign(selected_nord_city: selected_city_id)
     # Clear previously fetched servers
     |> assign(nord_servers: [])
     |> assign(best_nord_server_id: nil)
     |> assign(selected_nord_servers: MapSet.new())}
  end

  @impl true
  def handle_event("open_mullvad_dropdown", _params, socket) do
    {:noreply, assign(socket, show_mullvad_dropdown: true, mullvad_country_search: "")}
  end

  @impl true
  def handle_event("close_mullvad_dropdown", _params, socket) do
    current_country =
      Enum.find(socket.assigns.mullvad_countries, fn c ->
        c.code == socket.assigns.selected_mullvad_country
      end)

    name = if current_country, do: "#{current_country.name} (#{current_country.code})", else: ""

    {:noreply,
     assign(socket,
       show_mullvad_dropdown: false,
       mullvad_selected_country_name: name,
       mullvad_country_search: ""
     )}
  end

  @impl true
  def handle_event("search_mullvad_country", %{"value" => query}, socket) do
    {:noreply,
     assign(socket, mullvad_country_search: query, mullvad_selected_country_name: query)}
  end

  @impl true
  def handle_event("select_mullvad_country_item", %{"code" => country_code}, socket) do
    country = Enum.find(socket.assigns.mullvad_countries, fn c -> c.code == country_code end)
    name = if country, do: "#{country.name} (#{country.code})", else: ""

    servers =
      socket.assigns.mullvad_all_servers
      |> Enum.filter(fn s -> s.country_code == country_code end)
      |> Enum.sort_by(& &1.hostname)

    {:noreply,
     socket
     |> assign(selected_mullvad_country: country_code)
     |> assign(mullvad_selected_country_name: name)
     |> assign(mullvad_prefix: "Mullvad - #{country_code}")
     |> assign(show_mullvad_dropdown: false)
     |> assign(mullvad_country_search: "")
     |> assign(mullvad_country_servers: servers)
     |> assign(selected_mullvad_servers: MapSet.new())}
  end

  @impl true
  def handle_event("fetch_nord_servers", _params, socket) do
    country_id = socket.assigns.selected_nord_country
    access_token = socket.assigns.nord_access_token
    limit = socket.assigns.nord_limit
    selected_city_id = socket.assigns.selected_nord_city

    cond do
      country_id == "" or is_nil(country_id) ->
        {:noreply, put_flash(socket, :error, "Please select a country first.")}

      String.trim(access_token) == "" ->
        {:noreply,
         put_flash(socket, :error, "Access Token is required to authenticate with NordVPN.")}

      true ->
        # Set loading
        socket = assign(socket, nord_loading: true)

        # Call API to get PrivateKey from AccessToken first
        case Provider.fetch_nordvpn_private_key(access_token) do
          {:ok, private_key} ->
            socket = assign(socket, nord_private_key: private_key)
            send(self(), {:do_fetch_nord_servers, country_id, limit, selected_city_id})
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(nord_loading: false)
             |> put_flash(:error, "Failed to authenticate NordVPN: #{reason}")}
        end
    end
  end

  @impl true
  def handle_event("toggle_nord_server", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected_nord_servers

    new_selected =
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    {:noreply, assign(socket, selected_nord_servers: new_selected)}
  end

  @impl true
  def handle_event("toggle_all_nord_servers", _params, socket) do
    all_ids = socket.assigns.nord_servers |> Enum.map(& &1.id) |> MapSet.new()
    selected = socket.assigns.selected_nord_servers

    new_selected =
      if MapSet.size(selected) == MapSet.size(all_ids) do
        MapSet.new()
      else
        all_ids
      end

    {:noreply, assign(socket, selected_nord_servers: new_selected)}
  end

  @impl true
  def handle_event("import_nord_servers", _params, socket) do
    private_key = socket.assigns.nord_private_key
    address = socket.assigns.nord_address
    dns = socket.assigns.nord_dns
    prefix = socket.assigns.nord_prefix
    selected_ids = socket.assigns.selected_nord_servers

    cond do
      String.trim(private_key) == "" ->
        {:noreply, put_flash(socket, :error, "Private Key is required.")}

      String.trim(address) == "" ->
        {:noreply, put_flash(socket, :error, "Address is required.")}

      MapSet.size(selected_ids) == 0 ->
        {:noreply, put_flash(socket, :error, "Please select at least one server to import.")}

      true ->
        servers_to_import =
          socket.assigns.nord_servers
          |> Enum.filter(fn server -> MapSet.member?(selected_ids, server.id) end)

        profiles =
          Enum.map(servers_to_import, fn server ->
            wg_config =
              Provider.generate_wg_config(
                private_key,
                address,
                dns,
                server.pubkey,
                server.endpoint
              )

            %{
              name: "#{prefix} - #{server.name}",
              provider: "nordvpn",
              config: %{"wg_config" => wg_config}
            }
          end)

        case Provider.import_configs(profiles) do
          {:ok, %{success: success, failure: failure}} ->
            socket =
              socket
              |> put_flash(
                :info,
                "Successfully imported #{success} profiles. (Failures: #{failure})"
              )
              |> assign(selected_nord_servers: MapSet.new())
              |> assign_saved_configs()

            {:noreply, socket}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to import profiles.")}
        end
    end
  end

  @impl true
  def handle_event("save_nord_credentials", _params, socket) do
    access_token = socket.assigns.nord_access_token

    Setting.put_value("nord_access_token", access_token)

    {:noreply, put_flash(socket, :info, "NordVPN Credentials saved successfully.")}
  end

  # --- Mullvad Events ---

  @impl true
  def handle_event("change_mullvad_fields", params, socket) do
    private_key = Map.get(params, "private_key", socket.assigns.mullvad_private_key)
    address = Map.get(params, "address", socket.assigns.mullvad_address)
    dns = Map.get(params, "dns", socket.assigns.mullvad_dns)
    prefix = Map.get(params, "prefix", socket.assigns.mullvad_prefix)

    {:noreply,
     socket
     |> assign(mullvad_private_key: private_key)
     |> assign(mullvad_address: address)
     |> assign(mullvad_dns: dns)
     |> assign(mullvad_prefix: prefix)}
  end

  @impl true
  def handle_event("change_mullvad_country", %{"country_code" => country_code}, socket) do
    servers =
      socket.assigns.mullvad_all_servers
      |> Enum.filter(fn s -> s.country_code == country_code end)
      |> Enum.sort_by(& &1.hostname)

    {:noreply,
     socket
     |> assign(selected_mullvad_country: country_code)
     |> assign(mullvad_prefix: "Mullvad - #{country_code}")
     |> assign(mullvad_country_servers: servers)
     |> assign(selected_mullvad_servers: MapSet.new())}
  end

  @impl true
  def handle_event("toggle_mullvad_server", %{"hostname" => hostname}, socket) do
    selected = socket.assigns.selected_mullvad_servers

    new_selected =
      if MapSet.member?(selected, hostname) do
        MapSet.delete(selected, hostname)
      else
        MapSet.put(selected, hostname)
      end

    {:noreply, assign(socket, selected_mullvad_servers: new_selected)}
  end

  @impl true
  def handle_event("toggle_all_mullvad_servers", _params, socket) do
    all_hosts = socket.assigns.mullvad_country_servers |> Enum.map(& &1.hostname) |> MapSet.new()
    selected = socket.assigns.selected_mullvad_servers

    new_selected =
      if MapSet.size(selected) == MapSet.size(all_hosts) do
        MapSet.new()
      else
        all_hosts
      end

    {:noreply, assign(socket, selected_mullvad_servers: new_selected)}
  end

  @impl true
  def handle_event("import_mullvad_servers", _params, socket) do
    private_key = socket.assigns.mullvad_private_key
    address = socket.assigns.mullvad_address
    dns = socket.assigns.mullvad_dns
    prefix = socket.assigns.mullvad_prefix
    selected_hosts = socket.assigns.selected_mullvad_servers

    cond do
      String.trim(private_key) == "" ->
        {:noreply, put_flash(socket, :error, "Private Key is required.")}

      String.trim(address) == "" ->
        {:noreply, put_flash(socket, :error, "Address is required for Mullvad.")}

      MapSet.size(selected_hosts) == 0 ->
        {:noreply, put_flash(socket, :error, "Please select at least one server to import.")}

      true ->
        servers_to_import =
          socket.assigns.mullvad_country_servers
          |> Enum.filter(fn server -> MapSet.member?(selected_hosts, server.hostname) end)

        profiles =
          Enum.map(servers_to_import, fn server ->
            wg_config =
              Provider.generate_wg_config(
                private_key,
                address,
                dns,
                server.pubkey,
                server.endpoint
              )

            %{
              name: "#{prefix} - #{server.hostname} (#{server.city_name})",
              provider: "mullvad",
              config: %{"wg_config" => wg_config}
            }
          end)

        case Provider.import_configs(profiles) do
          {:ok, %{success: success, failure: failure}} ->
            socket =
              socket
              |> put_flash(
                :info,
                "Successfully imported #{success} Mullvad profiles. (Failures: #{failure})"
              )
              |> assign(selected_mullvad_servers: MapSet.new())
              |> assign_saved_configs()

            {:noreply, socket}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to import profiles.")}
        end
    end
  end

  @impl true
  def handle_event("save_mullvad_credentials", _params, socket) do
    private_key = socket.assigns.mullvad_private_key
    address = socket.assigns.mullvad_address

    Setting.put_value("mullvad_private_key", private_key)
    Setting.put_value("mullvad_address", address)

    {:noreply, put_flash(socket, :info, "Mullvad Credentials saved successfully.")}
  end

  # --- Bulk Import Events ---

  @impl true
  def handle_event("validate_bulk", params, socket) do
    paste_text = Map.get(params, "paste_text", socket.assigns.paste_text)
    paste_name = Map.get(params, "paste_name", socket.assigns.paste_name)

    {:noreply,
     socket
     |> assign(paste_text: paste_text)
     |> assign(paste_name: paste_name)}
  end

  @impl true
  def handle_event("save_bulk", params, socket) do
    paste_text = Map.get(params, "paste_text", "")
    paste_name = Map.get(params, "paste_name", "Imported WireGuard")

    all_profiles =
      if String.trim(paste_text) != "" do
        [
          %{
            name: paste_name,
            provider: "custom",
            config: %{"wg_config" => paste_text}
          }
        ]
      else
        []
      end

    if all_profiles == [] do
      {:noreply,
       put_flash(socket, :error, "Please upload a .conf file or paste configuration text.")}
    else
      case Provider.import_configs(all_profiles) do
        {:ok, %{success: success, failure: failure}} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Successfully imported #{success} profiles. (Failures: #{failure})"
           )
           |> assign(paste_text: "")
           |> assign(paste_name: "Imported WireGuard")
           |> assign_saved_configs()}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to import configurations.")}
      end
    end
  end

  @impl true
  def handle_event("delete_provider_config", %{"id" => id}, socket) do
    config = Hermit.Repo.get!(Hermit.Vpn.ProviderConfig, id)

    case Hermit.Repo.delete(config) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved VPN Configuration deleted.")
         |> assign_saved_configs()}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete configuration.")}
    end
  end

  # --- Async info handlers ---

  @impl true
  def handle_info(:load_nord_countries, socket) do
    countries = Provider.list_nordvpn_countries()
    default_country = List.first(countries)
    default_country_id = if default_country, do: default_country.id, else: ""
    default_country_code = if default_country, do: default_country.code, else: ""
    default_cities = if default_country, do: default_country[:cities] || [], else: []

    default_country_name =
      if default_country do
        server_cnt_str =
          if default_country[:server_count] > 0,
            do: " - #{default_country.server_count} servers",
            else: ""

        "#{default_country.name} (#{default_country.code})#{server_cnt_str}"
      else
        ""
      end

    {:noreply,
     socket
     |> assign(nord_countries: countries)
     |> assign(selected_nord_country: default_country_id)
     |> assign(nord_selected_country_name: default_country_name)
     |> assign(nord_cities: default_cities)
     |> assign(selected_nord_city: "")
     |> assign(nord_prefix: "NordVPN - #{default_country_code}")}
  end

  @impl true
  def handle_info({:do_fetch_nord_servers, country_id, limit, selected_city_id}, socket) do
    all_servers = Provider.fetch_nordvpn_servers_all(country_id)

    # Filter by city if a specific city is selected
    pool =
      if selected_city_id != "" and selected_city_id != nil do
        Enum.filter(all_servers, fn s -> s.city_id == selected_city_id end)
      else
        all_servers
      end

    # Group by subnet /24 (first 3 octets of IP) — same subnet = same datacenter = same ping
    # Pick 1 representative (lowest load) per subnet, cap at 80 representatives max
    representatives =
      pool
      |> Enum.group_by(fn s ->
        [ip, _] = String.split(s.endpoint, ":")
        ip |> String.split(".") |> Enum.take(3) |> Enum.join(".")
      end)
      |> Enum.map(fn {_subnet, list} -> Enum.min_by(list, & &1.load) end)
      |> Enum.sort_by(& &1.load)
      |> Enum.take(80)

    # Ping representatives (concurrency=10, safe for accurate measurements)
    pinged_reps = Provider.measure_pings(representatives)

    # Build lookup: subnet /24 -> measured ping
    subnet_ping_map =
      pinged_reps
      |> Enum.reduce(%{}, fn rep, acc ->
        [ip, _] = String.split(rep.endpoint, ":")
        subnet = ip |> String.split(".") |> Enum.take(3) |> Enum.join(".")
        Map.put(acc, subnet, rep[:ping])
      end)

    # Assign subnet-level ping to ALL servers in the pool, then sort by ping -> load
    servers =
      pool
      |> Enum.map(fn s ->
        [ip, _] = String.split(s.endpoint, ":")
        subnet = ip |> String.split(".") |> Enum.take(3) |> Enum.join(".")
        Map.put(s, :ping, Map.get(subnet_ping_map, subnet))
      end)
      |> Enum.sort(fn a, b ->
        cond do
          is_integer(a[:ping]) and is_nil(b[:ping]) -> true
          is_nil(a[:ping]) and is_integer(b[:ping]) -> false
          is_nil(a[:ping]) and is_nil(b[:ping]) -> a.load <= b.load
          a.ping == b.ping -> a.load <= b.load
          true -> a.ping < b.ping
        end
      end)
      # All Cities: keep only the best server per city for diversity
      # Specific City: show multiple servers from that city
      |> then(fn sorted ->
        if selected_city_id == "" or is_nil(selected_city_id) do
          Enum.uniq_by(sorted, & &1.city_id)
        else
          sorted
        end
      end)
      |> Enum.take(limit)

    best_server = Enum.find(servers, fn s -> is_integer(s[:ping]) end)
    best_server_id = if best_server, do: best_server.id, else: nil

    socket =
      socket
      |> assign(nord_servers: servers)
      |> assign(best_nord_server_id: best_server_id)
      |> assign(nord_loading: false)

    socket =
      if servers == [] do
        put_flash(socket, :error, "No recommended servers found for this selection.")
      else
        socket
      end

    {:noreply, socket}
  end

  # --- Helpers ---

  defp handle_progress(:wg_files, entry, socket) do
    if entry.done? do
      consume_uploaded_entries(socket, :wg_files, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, content} ->
            name = Path.rootname(entry.client_name)
            {:ok, {name, content}}

          _ ->
            {:error, :read_failed}
        end
      end)
      |> case do
        [{name, content}] ->
          socket =
            socket
            |> assign(paste_name: name)
            |> assign(paste_text: content)
            |> put_flash(:info, "Auto-filled configuration from file #{entry.client_name}.")

          {:noreply, socket}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp assign_saved_configs(socket) do
    saved_configs = Hermit.Repo.all(Hermit.Vpn.ProviderConfig) |> Enum.sort_by(& &1.name)
    assign(socket, saved_configs: saved_configs)
  end

  def filter_countries(countries, search_query) do
    query = String.downcase(String.trim(search_query))

    if query == "" do
      countries
    else
      Enum.filter(countries, fn c ->
        String.contains?(String.downcase(c.name), query) or
          String.contains?(String.downcase(c.code), query)
      end)
    end
  end
end
