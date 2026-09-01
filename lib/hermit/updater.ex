defmodule Hermit.Updater do
  @moduledoc """
  Manages version checking via GitHub Releases and 1-click container self-upgrades
  via the Docker Engine API socket.
  """
  use GenServer
  require Logger

  @github_releases_url "https://api.github.com/repos/quaywin/hermit/releases/latest"
  @check_interval_ms 6 * 60 * 60 * 1000
  @pubsub_topic "hermit:updates"

  # ============================================================================
  # Public Client API
  # ============================================================================

  @doc """
  Starts the Updater GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the PubSub topic used for update notifications.
  """
  def topic, do: @pubsub_topic

  @doc """
  Returns the current running version of Hermit.
  """
  def current_version do
    case Application.spec(:hermit, :vsn) do
      nil -> "0.2.1"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Checks if the Docker Unix domain socket is available for self-upgrading.
  """
  def docker_socket_available? do
    File.exists?("/var/run/docker.sock")
  end

  @doc """
  Retrieves the current update status map.
  """
  def status do
    GenServer.call(__MODULE__, :get_status)
  rescue
    _ ->
      %{
        current_version: current_version(),
        latest_version: nil,
        update_available?: false,
        release_url: nil,
        release_notes: nil,
        published_at: nil,
        checked_at: nil,
        docker_socket_available?: docker_socket_available?(),
        is_upgrading?: false,
        upgrade_status: nil,
        error: nil
      }
  end

  @doc """
  Forces an immediate check for updates from GitHub.
  """
  def check_updates(force \\ true) do
    GenServer.call(__MODULE__, {:check_updates, force}, 15_000)
  end

  @doc """
  Triggers 1-Click container self-upgrade.
  """
  def start_upgrade do
    GenServer.call(__MODULE__, :start_upgrade, 60_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    initial_state = %{
      current_version: current_version(),
      latest_version: nil,
      update_available?: false,
      release_url: nil,
      release_notes: nil,
      published_at: nil,
      checked_at: nil,
      docker_socket_available?: docker_socket_available?(),
      is_upgrading?: false,
      upgrade_status: nil,
      error: nil
    }

    # Perform initial check after short boot delay (5s)
    Process.send_after(self(), :initial_check, 5_000)
    # Schedule periodic checks every 6 hours
    :timer.send_interval(@check_interval_ms, :periodic_check)

    {:ok, initial_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    state = Map.put(state, :docker_socket_available?, docker_socket_available?())
    {:reply, state, state}
  end

  @impl true
  def handle_call({:check_updates, _force}, _from, state) do
    new_state = fetch_latest_release(state)
    broadcast_status(new_state)
    {:reply, new_state, new_state}
  end

  @impl true
  def handle_call(:start_upgrade, _from, %{is_upgrading?: true} = state) do
    {:reply, {:error, :already_upgrading}, state}
  end

  def handle_call(:start_upgrade, _from, state) do
    if not docker_socket_available?() do
      {:reply, {:error, :docker_socket_not_available}, state}
    else
      upgrading_state = %{
        state
        | is_upgrading?: true,
          upgrade_status: "Pulling latest Docker image...",
          error: nil
      }

      broadcast_status(upgrading_state)

      Task.start(fn ->
        case perform_upgrade_steps() do
          {:ok, _} ->
            Logger.info("[Updater] Upgrade triggered successfully. Container recreating...")

          {:error, reason} ->
            Logger.error("[Updater] Upgrade failed: #{inspect(reason)}")
            GenServer.cast(__MODULE__, {:upgrade_failed, to_string(reason)})
        end
      end)

      {:reply, {:ok, :upgrading}, upgrading_state}
    end
  end

  @impl true
  def handle_cast({:upgrade_failed, reason}, state) do
    new_state = %{state | is_upgrading?: false, upgrade_status: nil, error: reason}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:initial_check, state) do
    new_state = fetch_latest_release(state)
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:periodic_check, state) do
    new_state = fetch_latest_release(state)
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  # ============================================================================
  # Internal Helper Functions
  # ============================================================================

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(Hermit.PubSub, @pubsub_topic, {:updater_status, state})
  rescue
    _ -> :ok
  end

  @doc false
  def fetch_latest_release(state) do
    cur_ver = current_version()

    case Req.get(@github_releases_url,
           headers: [
             {"user-agent", "Hermit-Orchestrator"},
             {"accept", "application/vnd.github.v3+json"}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        tag_name = body["tag_name"] || ""
        latest_ver = String.trim_leading(tag_name, "v")
        release_notes = body["body"] || ""
        release_url = body["html_url"] || ""
        published_at = body["published_at"]

        update_available? = is_newer_version?(cur_ver, latest_ver)

        %{
          state
          | current_version: cur_ver,
            latest_version: latest_ver,
            update_available?: update_available?,
            release_url: release_url,
            release_notes: release_notes,
            published_at: published_at,
            checked_at: DateTime.utc_now(),
            error: nil
        }

      {:ok, %{status: 404}} ->
        %{state | current_version: cur_ver, checked_at: DateTime.utc_now(), error: nil}

      {:ok, %{status: status}} ->
        Logger.warning("[Updater] GitHub API returned HTTP status #{status}")

        %{
          state
          | current_version: cur_ver,
            checked_at: DateTime.utc_now(),
            error: "GitHub API HTTP #{status}"
        }

      {:error, reason} ->
        Logger.warning("[Updater] Failed to reach GitHub API: #{inspect(reason)}")

        %{
          state
          | current_version: cur_ver,
            checked_at: DateTime.utc_now(),
            error: "Network error checking update"
        }
    end
  rescue
    e ->
      Logger.warning("[Updater] Exception checking update: #{inspect(e)}")

      %{
        state
        | current_version: current_version(),
          checked_at: DateTime.utc_now(),
          error: "Check failed"
      }
  end

  @doc """
  Compares two semantic version strings. Returns true if latest > current.
  """
  def is_newer_version?(current_str, latest_str)
      when is_binary(current_str) and is_binary(latest_str) do
    with {:ok, v_curr} <- parse_version(current_str),
         {:ok, v_late} <- parse_version(latest_str) do
      Version.compare(v_late, v_curr) == :gt
    else
      _ ->
        latest_str != "" and latest_str != current_str
    end
  end

  def is_newer_version?(_, _), do: false

  defp parse_version(v) do
    v
    |> String.trim_leading("v")
    |> String.trim()
    |> Version.parse()
  end

  @doc """
  Executes Docker Engine API calls to pull the latest image and recreate the container.
  """
  def perform_upgrade_steps do
    socket_path = "/var/run/docker.sock"

    if not File.exists?(socket_path) do
      {:error, "Docker socket /var/run/docker.sock not found. Please ensure it is mounted."}
    else
      image_name = "ghcr.io/quaywin/hermit:latest"

      # 1. Pull newest image from GHCR
      Logger.info("[Updater] Pulling #{image_name} via Docker API...")
      pull_url = "http://localhost/images/create?fromImage=ghcr.io/quaywin/hermit&tag=latest"

      case docker_curl_post(socket_path, pull_url) do
        {:ok, _} ->
          Logger.info("[Updater] Image pulled successfully. Inspecting existing container...")

          # 2. Inspect current running container to duplicate port/env configuration
          inspect_url = "http://localhost/containers/hermit_orchestrator/json"

          case docker_curl_get_json(socket_path, inspect_url) do
            {:ok, container_info} ->
              # 3. Create next container with newly pulled image
              create_url = "http://localhost/containers/create?name=hermit_orchestrator_next"

              create_payload = %{
                "Image" => image_name,
                "Env" => get_in(container_info, ["Config", "Env"]) || [],
                "Cmd" => get_in(container_info, ["Config", "Cmd"]),
                "HostConfig" => get_in(container_info, ["HostConfig"]) || %{}
              }

              case docker_curl_post_json(socket_path, create_url, create_payload) do
                {:ok, _} ->
                  Logger.info("[Updater] Next container created. Spawning swap helper...")

                  # 4. Spawn a lightweight transient runner to swap containers
                  swap_script =
                    "sleep 1 && " <>
                      "curl -s -X POST --unix-socket /var/run/docker.sock http://localhost/containers/hermit_orchestrator/stop && " <>
                      "curl -s -X DELETE --unix-socket /var/run/docker.sock 'http://localhost/containers/hermit_orchestrator?v=1' && " <>
                      "curl -s -X POST --unix-socket /var/run/docker.sock http://localhost/containers/hermit_orchestrator_next/rename?name=hermit_orchestrator && " <>
                      "curl -s -X POST --unix-socket /var/run/docker.sock http://localhost/containers/hermit_orchestrator/start"

                  runner_payload = %{
                    "Image" => image_name,
                    "Cmd" => ["sh", "-c", swap_script],
                    "HostConfig" => %{
                      "Binds" => ["/var/run/docker.sock:/var/run/docker.sock"],
                      "AutoRemove" => true
                    }
                  }

                  runner_create_url =
                    "http://localhost/containers/create?name=hermit_upgrade_runner"

                  case docker_curl_post_json(socket_path, runner_create_url, runner_payload) do
                    {:ok, runner_res} ->
                      runner_id = runner_res["Id"] || "hermit_upgrade_runner"

                      docker_curl_post(
                        socket_path,
                        "http://localhost/containers/#{runner_id}/start"
                      )

                      {:ok, :upgrading}

                    {:error, reason} ->
                      {:error, "Failed to create swap runner: #{reason}"}
                  end

                {:error, reason} ->
                  {:error, "Failed to create upgraded container: #{reason}"}
              end

            {:error, reason} ->
              {:error, "Failed to inspect current container: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Failed to pull newest image: #{reason}"}
      end
    end
  end

  # ============================================================================
  # Low-level Docker Socket HTTP helpers via curl
  # ============================================================================

  defp docker_curl_post(socket_path, url) do
    case System.cmd("curl", ["-s", "-X", "POST", "--unix-socket", socket_path, url],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {err, _code} -> {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp docker_curl_get_json(socket_path, url) do
    case System.cmd("curl", ["-s", "--unix-socket", socket_path, url], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, err} -> {:error, "JSON decode error: #{inspect(err)} (Output: #{output})"}
        end

      {err, _code} ->
        {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp docker_curl_post_json(socket_path, url, data_map) do
    json_payload = Jason.encode!(data_map)

    case System.cmd(
           "curl",
           [
             "-s",
             "-X",
             "POST",
             "-H",
             "Content-Type: application/json",
             "-d",
             json_payload,
             "--unix-socket",
             socket_path,
             url
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:ok, output}
        end

      {err, _code} ->
        {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
