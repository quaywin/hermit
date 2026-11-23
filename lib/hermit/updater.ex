defmodule Hermit.Updater do
  @moduledoc """
  Manages version checking via GitHub Releases and 1-click Native self-upgrades
  using atomic symlink swaps under `/opt/hermit/releases` and `systemd`.
  """
  use GenServer
  require Logger

  @repo "quaywin/hermit"
  @github_releases_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @install_root "/opt/hermit"
  @bin_dir "/opt/hermit/bin"
  @tailscale_version "1.98.4"
  @threeproxy_version "1.0.3"
  @service_name "hermit.service"
  @check_interval_ms 6 * 60 * 60 * 1000
  @pubsub_topic "hermit:updates"

  # ============================================================================
  # Public Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic, do: @pubsub_topic

  def current_version do
    case Application.spec(:hermit, :vsn) do
      nil -> "0.2.1"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Checks if the host is running a Native systemd installation under `/opt/hermit`
  capable of 1-click self-upgrading.
  """
  def native_upgrade_available? do
    :os.type() == {:unix, :linux} and
      File.dir?(Path.join(@install_root, "releases")) and
      not is_nil(System.find_executable("systemctl")) and
      not is_nil(System.find_executable("tar"))
  end

  @status_table :hermit_updater_status

  def status do
    case :ets.whereis(@status_table) do
      :undefined ->
        default_status()

      _ ->
        case :ets.lookup(@status_table, :status) do
          [{:status, state}] ->
            state

          [] ->
            default_status()
        end
    end
  rescue
    _ -> default_status()
  end

  defp default_status do
    %{
      current_version: current_version(),
      latest_version: nil,
      update_available?: false,
      release_url: nil,
      release_notes: nil,
      published_at: nil,
      checked_at: nil,
      native_upgrade_available?: native_upgrade_available?(),
      is_upgrading?: false,
      upgrade_status: nil,
      error: nil
    }
  end

  defp cache_status(state) do
    if :ets.whereis(@status_table) != :undefined do
      :ets.insert(@status_table, {:status, state})
    end

    state
  rescue
    _ -> state
  end

  def check_updates(force \\ true) do
    GenServer.call(__MODULE__, {:check_updates, force}, 15_000)
  end

  def start_upgrade do
    GenServer.call(__MODULE__, :start_upgrade, 60_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@status_table) == :undefined do
      :ets.new(@status_table, [:set, :public, :named_table, read_concurrency: true])
    end

    initial_state = default_status() |> cache_status()

    Process.send_after(self(), :initial_check, 5_000)
    :timer.send_interval(@check_interval_ms, :periodic_check)

    {:ok, initial_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    state =
      state
      |> Map.put(:native_upgrade_available?, native_upgrade_available?())
      |> cache_status()

    {:reply, state, state}
  end

  @impl true
  def handle_call({:check_updates, _force}, from, state) do
    parent = self()

    Task.start(fn ->
      new_state = fetch_latest_release(state)
      GenServer.reply(from, new_state)
      send(parent, {:release_fetched, new_state})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:start_upgrade, _from, %{is_upgrading?: true} = state) do
    {:reply, {:error, :already_upgrading}, state}
  end

  def handle_call(:start_upgrade, _from, state) do
    if not native_upgrade_available?() do
      {:reply, {:error, :native_upgrade_not_available}, state}
    else
      upgrading_state =
        %{
          state
          | is_upgrading?: true,
            upgrade_status: "Downloading latest release archive...",
            error: nil
        }
        |> cache_status()

      broadcast_status(upgrading_state)

      Task.start(fn ->
        case perform_upgrade_steps() do
          {:ok, _} ->
            Logger.info("[Updater] Native upgrade prepared. Restarting #{@service_name}...")

          {:error, reason} ->
            Logger.error("[Updater] Native upgrade failed: #{inspect(reason)}")
            GenServer.cast(__MODULE__, {:upgrade_failed, to_string(reason)})
        end
      end)

      {:reply, {:ok, :upgrading}, upgrading_state}
    end
  end

  @impl true
  def handle_cast({:upgrade_failed, reason}, state) do
    new_state =
      %{state | is_upgrading?: false, upgrade_status: nil, error: reason}
      |> cache_status()

    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:initial_check, state) do
    parent = self()

    Task.start(fn ->
      new_state = fetch_latest_release(state)
      send(parent, {:release_fetched, new_state})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_check, state) do
    parent = self()

    Task.start(fn ->
      new_state = fetch_latest_release(state)
      send(parent, {:release_fetched, new_state})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:release_fetched, new_state}, state) do
    merged = Map.merge(state, new_state) |> cache_status()
    broadcast_status(merged)
    {:noreply, merged}
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
  Downloads the latest Native release tarball matching the host CPU architecture,
  extracts it into `/opt/hermit/releases/<timestamp>`, atomically updates the
  `/opt/hermit/current` symlink, prunes old releases, and restarts `hermit.service`.
  """
  def perform_upgrade_steps do
    with {:ok, arch} <- detect_arch(),
         {:ok, tmp_tar} <- download_release_tarball(arch),
         :ok <- verify_tarball_checksum(tmp_tar, arch),
         {:ok, release_dir} <- extract_release(tmp_tar),
         :ok <- switch_current_symlink(release_dir),
         :ok <- prune_old_releases(),
         :ok <- sync_runtime_binaries(arch),
         :ok <- restart_systemd_service() do
      {:ok, :upgrading}
    end
  end

  defp detect_arch do
    case System.cmd("uname", ["-m"], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          arch when arch in ["x86_64", "amd64"] -> {:ok, "amd64"}
          arch when arch in ["aarch64", "arm64"] -> {:ok, "arm64"}
          other -> {:error, "Unsupported architecture: #{other}"}
        end

      {err, _} ->
        {:error, "Failed to detect architecture: #{err}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp download_release_tarball(arch) do
    url = "https://github.com/#{@repo}/releases/latest/download/hermit-linux-#{arch}.tar.gz"

    tmp_tar =
      Path.join(System.tmp_dir!(), "hermit-upgrade-#{System.unique_integer([:positive])}.tar.gz")

    Logger.info("[Updater] Downloading #{url}...")

    case Req.get(url,
           headers: [{"user-agent", "Hermit-Orchestrator"}],
           into: File.stream!(tmp_tar),
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200}} ->
        {:ok, tmp_tar}

      {:ok, %{status: status}} ->
        File.rm(tmp_tar)
        {:error, "Failed to download release archive (HTTP #{status})"}

      {:error, reason} ->
        File.rm(tmp_tar)
        {:error, "Download failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp verify_tarball_checksum(tmp_tar, arch) do
    sums_url = "https://github.com/#{@repo}/releases/latest/download/SHA256SUMS"
    tarball_name = "hermit-linux-#{arch}.tar.gz"

    case Req.get(sums_url,
           headers: [{"user-agent", "Hermit-Orchestrator"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case verify_sha256_against_sums(tmp_tar, tarball_name, body) do
          :ok ->
            :ok

          {:error, _} = err ->
            File.rm(tmp_tar)
            err
        end

      {:ok, %{status: status}} ->
        File.rm(tmp_tar)
        {:error, "Failed to download SHA256SUMS (HTTP #{status})"}

      {:error, reason} ->
        File.rm(tmp_tar)
        {:error, "SHA256SUMS download failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      File.rm(tmp_tar)
      {:error, Exception.message(e)}
  end

  @doc false
  def verify_sha256_against_sums(file_path, tarball_name, sums_body) do
    expected =
      sums_body
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [hash, name] when name == tarball_name -> String.downcase(hash)
          [hash, "*" <> name] when name == tarball_name -> String.downcase(hash)
          _ -> nil
        end
      end)

    if is_nil(expected) do
      {:error, "Checksum entry not found for #{tarball_name}"}
    else
      actual =
        file_path
        |> File.stream!(65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
          :crypto.hash_update(acc, chunk)
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      if actual == expected do
        :ok
      else
        {:error, "Checksum mismatch for #{tarball_name}"}
      end
    end
  end

  defp extract_release(tmp_tar) do
    release_id =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d%H%M%S")

    release_dir = Path.join([@install_root, "releases", release_id])
    File.mkdir_p!(release_dir)

    try do
      case System.cmd("tar", ["-xzf", tmp_tar, "-C", release_dir], stderr_to_stdout: true) do
        {_, 0} ->
          _ = File.chmod(Path.join([release_dir, "bin", "server"]), 0o755)
          _ = File.chmod(Path.join([release_dir, "bin", "hermit"]), 0o755)
          {:ok, release_dir}

        {err, code} ->
          File.rm_rf(release_dir)
          {:error, "Failed to extract release tarball (code #{code}): #{err}"}
      end
    after
      File.rm(tmp_tar)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp switch_current_symlink(release_dir) do
    current_link = Path.join(@install_root, "current")

    case System.cmd("ln", ["-sfn", release_dir, current_link], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, code} -> {:error, "Failed to update symlink (code #{code}): #{err}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp prune_old_releases do
    releases_dir = Path.join(@install_root, "releases")

    case File.ls(releases_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort(:desc)
        |> Enum.drop(2)
        |> Enum.each(fn old ->
          File.rm_rf(Path.join(releases_dir, old))
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp sync_runtime_binaries(arch) do
    File.mkdir_p!(@bin_dir)
    sync_tailscale(arch)
    sync_threeproxy(arch)
    :ok
  rescue
    e ->
      Logger.warning("[Updater] Failed to sync runtime binaries: #{inspect(e)}")
      :ok
  end

  defp sync_tailscale(arch) do
    ts_bin = Path.join(@bin_dir, "tailscale")
    tsd_bin = Path.join(@bin_dir, "tailscaled")

    current_ver =
      if File.exists?(ts_bin) do
        case System.cmd(ts_bin, ["version"], stderr_to_stdout: true) do
          {out, 0} -> out |> String.split("\n") |> List.first("") |> String.trim()
          _ -> ""
        end
      else
        ""
      end

    has_host_ts? =
      not is_nil(System.find_executable("tailscale")) and
        not is_nil(System.find_executable("tailscaled"))

    need_install? =
      (not File.exists?(ts_bin) and not has_host_ts?) or
        (File.exists?(ts_bin) and current_ver != @tailscale_version)

    if need_install? do
      url = "https://pkgs.tailscale.com/stable/tailscale_#{@tailscale_version}_#{arch}.tgz"
      tmp_dir = Path.join(System.tmp_dir!(), "hermit-ts-#{System.unique_integer([:positive])}")
      tmp_tgz = Path.join(tmp_dir, "tailscale.tgz")
      File.mkdir_p!(tmp_dir)

      try do
        case Req.get(url, into: File.stream!(tmp_tgz), receive_timeout: 60_000) do
          {:ok, %{status: 200}} ->
            case System.cmd("tar", ["-xzf", tmp_tgz, "-C", tmp_dir], stderr_to_stdout: true) do
              {_, 0} ->
                extracted = Path.join(tmp_dir, "tailscale_#{@tailscale_version}_#{arch}")
                atomic_install_binary(Path.join(extracted, "tailscale"), ts_bin)
                atomic_install_binary(Path.join(extracted, "tailscaled"), tsd_bin)
                Logger.info("[Updater] Synced Tailscale #{@tailscale_version} in #{@bin_dir}")

              {err, _} ->
                Logger.warning("[Updater] Failed to extract Tailscale: #{err}")
            end

          other ->
            Logger.warning("[Updater] Failed to download Tailscale: #{inspect(other)}")
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  defp atomic_install_binary(src, dst) do
    tmp_dst = "#{dst}.tmp.#{System.unique_integer([:positive])}"
    File.cp!(src, tmp_dst)
    File.chmod!(tmp_dst, 0o755)
    File.rename!(tmp_dst, dst)
  end

  defp sync_threeproxy(arch) do
    proxy_bin = Path.join(@bin_dir, "3proxy")

    current_ver =
      if File.exists?(proxy_bin) do
        case System.cmd(proxy_bin, ["--version"], stderr_to_stdout: true) do
          {out, _} ->
            case Regex.run(~r/\d+\.\d+\.\d+/, out) do
              [v] -> v
              _ -> ""
            end

          _ ->
            ""
        end
      else
        ""
      end

    too_small? =
      case File.stat(proxy_bin) do
        {:ok, %{size: size}} -> size < 20_000
        _ -> true
      end

    if too_small? or (current_ver != "" and current_ver != @threeproxy_version) do
      if System.find_executable("dpkg-deb") do
        tp_arch = if arch == "amd64", do: "x86_64", else: "arm64"

        url =
          "https://github.com/3proxy/3proxy/releases/download/#{@threeproxy_version}/3proxy-#{@threeproxy_version}.#{tp_arch}.deb"

        tmp_dir = Path.join(System.tmp_dir!(), "hermit-3p-#{System.unique_integer([:positive])}")
        tmp_deb = Path.join(tmp_dir, "3proxy.deb")
        extract_dir = Path.join(tmp_dir, "extracted")
        File.mkdir_p!(extract_dir)

        try do
          case Req.get(url, into: File.stream!(tmp_deb), receive_timeout: 60_000) do
            {:ok, %{status: 200}} ->
              case System.cmd("dpkg-deb", ["-x", tmp_deb, extract_dir], stderr_to_stdout: true) do
                {_, 0} ->
                  bin_path =
                    ["**/bin/3proxy", "**/sbin/3proxy"]
                    |> Enum.flat_map(&Path.wildcard(Path.join(extract_dir, &1)))
                    |> Enum.find(&File.regular?/1)

                  if bin_path do
                    atomic_install_binary(bin_path, proxy_bin)
                    Logger.info("[Updater] Synced 3proxy #{@threeproxy_version} in #{@bin_dir}")
                  end

                {err, _} ->
                  Logger.warning("[Updater] Failed to extract 3proxy .deb: #{err}")
              end

            other ->
              Logger.warning("[Updater] Failed to download 3proxy: #{inspect(other)}")
          end
        after
          File.rm_rf(tmp_dir)
        end
      end
    end
  end

  defp restart_systemd_service do
    case System.cmd("systemctl", ["restart", "--no-block", @service_name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, code} -> {:error, "Failed to restart #{@service_name} (code #{code}): #{err}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
