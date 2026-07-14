defmodule Hermit.Vpn.Provider do
  @moduledoc """
  Helper module to interface with VPN provider APIs (NordVPN, Mullvad)
  and build WireGuard outbound profiles.
  """
  require Logger
  alias Hermit.Vpn.ProviderConfig

  @doc """
  Fetches countries list from NordVPN API.
  If the API call fails, it falls back to a list of common countries.
  """
  def list_nordvpn_countries do
    if mock?() do
      [
        %{id: 228, name: "United States", code: "US"},
        %{id: 194, name: "Singapore", code: "SG"}
      ]
    else
      url = "https://api.nordvpn.com/v1/servers/countries"

      case Req.get(url, retry: false, receive_timeout: 5000) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          countries =
            body
            |> Enum.map(fn
              %{"id" => id, "name" => name, "code" => code} ->
                %{id: id, name: name, code: code}

              _ ->
                nil
            end)
            |> Enum.reject(&is_nil/1)

          if countries == [] do
            Logger.warning("NordVPN API returned no valid countries, using fallback list.")
            fallback_countries()
          else
            Enum.sort_by(countries, & &1.name)
          end

        error ->
          Logger.error("Failed to fetch NordVPN countries: #{inspect(error)}")
          fallback_countries()
      end
    end
  end

  @doc """
  Exchanges a NordVPN Access Token for the account's NordLynx private key.
  """
  def fetch_nordvpn_private_key(access_token) do
    if mock?() do
      if access_token == "invalid_token" do
        {:error, "Invalid Access Token or API error"}
      else
        {:ok, "mocked_private_key_from_token"}
      end
    else
      url = "https://api.nordvpn.com/v1/users/services/credentials"

      case Req.get(url,
             auth: {:basic, "token:#{String.trim(access_token)}"},
             retry: false,
             receive_timeout: 5000
           ) do
        {:ok, %{status: 200, body: %{"nordlynx_private_key" => private_key}}}
        when is_binary(private_key) ->
          {:ok, private_key}

        error ->
          Logger.error("Failed to fetch NordVPN credentials from token: #{inspect(error)}")
          {:error, "Invalid Access Token or API error"}
      end
    end
  end

  @doc """
  Fetches recommended WireGuard servers for a specific country from NordVPN API.
  """
  def fetch_nordvpn_servers(country_id, limit \\ 15) do
    if mock?() do
      [
        %{
          id: 1,
          name: "United States #1",
          endpoint: "1.1.1.1:51820",
          pubkey: "nord_pubkey_1",
          hostname: "us1.nordvpn.com",
          load: 15,
          city: "New York"
        },
        %{
          id: 2,
          name: "United States #2",
          endpoint: "2.2.2.2:51820",
          pubkey: "nord_pubkey_2",
          hostname: "us2.nordvpn.com",
          load: 75,
          city: "Los Angeles"
        }
      ]
    else
      url = "https://api.nordvpn.com/v1/servers/recommendations"

      params = [
        {"filters[servers_technologies][identifier]", "wireguard_udp"},
        {"filters[country_id]", to_string(country_id)},
        {"limit", to_string(limit)}
      ]

      case Req.get(url, params: params, retry: false, receive_timeout: 5000) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          body
          |> Enum.map(fn server ->
            name = Map.get(server, "name", "NordVPN Server")
            station = Map.get(server, "station")
            hostname = Map.get(server, "hostname")
            load = Map.get(server, "load", 0)

            city =
              case Map.get(server, "locations", []) do
                [%{"country" => %{"city" => %{"name" => city_name}}} | _] -> city_name
                _ -> nil
              end

            # Find WireGuard public key from technologies list
            pubkey =
              server
              |> Map.get("technologies", [])
              |> Enum.find(fn tech -> Map.get(tech, "identifier") == "wireguard_udp" end)
              |> case do
                nil ->
                  nil

                tech ->
                  tech
                  |> Map.get("metadata", [])
                  |> Enum.find(fn meta -> Map.get(meta, "name") == "public_key" end)
                  |> case do
                    nil -> nil
                    meta -> Map.get(meta, "value")
                  end
              end

            if station && pubkey do
              %{
                id: Map.get(server, "id"),
                name: name,
                endpoint: "#{station}:51820",
                pubkey: pubkey,
                hostname: hostname,
                load: load,
                city: city
              }
            else
              nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        error ->
          Logger.error("Failed to fetch NordVPN recommended servers: #{inspect(error)}")
          []
      end
    end
  end

  @doc """
  Fetches all active Mullvad WireGuard servers.
  Returns a list of servers with country/city metadata.
  """
  def fetch_mullvad_servers do
    if mock?() do
      [
        %{
          hostname: "us-mia-wg-001",
          country_code: "US",
          country_name: "United States",
          city_name: "Miami",
          endpoint: "3.3.3.3:51820",
          pubkey: "mullvad_pubkey_1",
          network_port_speed: 10,
          owned: true
        },
        %{
          hostname: "sg-sin-wg-001",
          country_code: "SG",
          country_name: "Singapore",
          city_name: "Singapore",
          endpoint: "4.4.4.4:51820",
          pubkey: "mullvad_pubkey_2",
          network_port_speed: 1,
          owned: false
        }
      ]
    else
      url = "https://api.mullvad.net/www/v1/public-servers/"

      case Req.get(url, retry: false, receive_timeout: 5000) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          body
          |> Enum.filter(fn server ->
            # Only include active WireGuard servers with public key and IPv4 address
            Map.get(server, "active") == true &&
              Map.get(server, "pubkey") != nil &&
              Map.get(server, "ipv4_addr_in") != nil
          end)
          |> Enum.map(fn server ->
            %{
              hostname: Map.get(server, "hostname"),
              country_code: Map.get(server, "country_code") |> String.upcase(),
              country_name: Map.get(server, "country_name"),
              city_name: Map.get(server, "city_name"),
              endpoint: "#{Map.get(server, "ipv4_addr_in")}:51820",
              pubkey: Map.get(server, "pubkey"),
              network_port_speed: Map.get(server, "network_port_speed", 1),
              owned: Map.get(server, "owned", false)
            }
          end)

        error ->
          Logger.error("Failed to fetch Mullvad servers: #{inspect(error)}")
          []
      end
    end
  end

  @doc """
  Generates WireGuard configuration text from interface and peer information.
  """
  def generate_wg_config(private_key, address, dns, peer_pubkey, peer_endpoint) do
    """
    [Interface]
    PrivateKey = #{String.trim(private_key)}
    Address = #{String.trim(address)}
    DNS = #{String.trim(dns)}

    [Peer]
    PublicKey = #{String.trim(peer_pubkey)}
    Endpoint = #{String.trim(peer_endpoint)}
    AllowedIPs = 0.0.0.0/0
    """
  end

  @doc """
  Imports a list of generated configurations into ProviderConfig database.
  """
  def import_configs(configs) do
    # configs: list of map %{name: name, provider: provider, config: %{wg_config: wg_config}}
    results =
      Enum.map(configs, fn params ->
        changeset = ProviderConfig.changeset(%ProviderConfig{}, params)
        Hermit.Repo.insert(changeset)
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)
    failure_count = length(results) - success_count

    {:ok, %{success: success_count, failure: failure_count}}
  end

  @doc """
  Measures latency (ping) in parallel to a list of servers.
  Returns the list of servers with a `:ping` field populated.
  """
  def measure_pings(servers) do
    if mock?() do
      Enum.map(servers, fn server ->
        # Return mock pings instantly based on ID
        Map.put(server, :ping, server.id * 15)
      end)
    else
      results =
        servers
        |> Task.async_stream(
          fn server ->
            [ip, _] = String.split(server.endpoint, ":")
            ping_val = measure_ping(ip)
            Map.put(server, :ping, ping_val)
          end,
          max_concurrency: 15,
          timeout: 2500,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      Enum.zip_with(servers, results, fn original_server, result ->
        case result do
          {:ok, updated_server} -> updated_server
          _ -> Map.put(original_server, :ping, nil)
        end
      end)
    end
  end

  defp measure_ping(ip) do
    try do
      case System.cmd(
             "curl",
             [
               "-o",
               "/dev/null",
               "-s",
               "-w",
               "%{time_connect}",
               "--connect-timeout",
               "2",
               "http://#{ip}"
             ],
             stderr_to_stdout: false
           ) do
        {output, _exit_code} ->
          case Float.parse(String.trim(output)) do
            {val, _} when val > 0.0 -> round(val * 1000)
            _ -> nil
          end

        _ ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  # Fallback country list for NordVPN if their API is offline
  defp fallback_countries do
    [
      %{id: 228, name: "United States", code: "US"},
      %{id: 227, name: "United Kingdom", code: "GB"},
      %{id: 81, name: "Germany", code: "DE"},
      %{id: 108, name: "Japan", code: "JP"},
      %{id: 194, name: "Singapore", code: "SG"},
      %{id: 38, name: "Canada", code: "CA"},
      %{id: 74, name: "France", code: "FR"},
      %{id: 153, name: "Netherlands", code: "NL"},
      %{id: 13, name: "Australia", code: "AU"},
      %{id: 97, name: "Hong Kong", code: "HK"},
      %{id: 208, name: "South Korea", code: "KR"}
    ]
  end

  defp mock? do
    config = Application.get_env(:hermit, :vpn, [])
    Keyword.get(config, :mock, false)
  end
end
