defmodule HermitWeb.SystemLive do
  use HermitWeb, :live_view
  alias Hermit.Updater

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, Updater.topic())
    end

    status = Updater.status()

    {:ok,
     socket
     |> assign(
       active_tab: :system,
       updater_status: status,
       show_upgrade_modal: false,
       is_checking: false,
       system_info: get_system_info()
     )}
  end

  @impl true
  def handle_event("check_updates", _params, socket) do
    status = Updater.check_updates(true)

    msg =
      if status.update_available? do
        "New version #{status.latest_version} is available!"
      else
        "Hermit is already running the latest version (v#{status.current_version})."
      end

    {:noreply,
     socket
     |> assign(updater_status: status, is_checking: false)
     |> put_flash(:info, msg)}
  end

  @impl true
  def handle_event("open_upgrade_modal", _params, socket) do
    {:noreply, assign(socket, show_upgrade_modal: true)}
  end

  @impl true
  def handle_event("close_upgrade_modal", _params, socket) do
    {:noreply, assign(socket, show_upgrade_modal: false)}
  end

  @impl true
  def handle_event("confirm_upgrade", _params, socket) do
    case Updater.start_upgrade() do
      {:ok, :upgrading} ->
        {:noreply,
         socket
         |> assign(show_upgrade_modal: false)
         |> put_flash(
           :info,
           "Upgrade initiated. Downloading latest release and restarting hermit.service..."
         )}

      {:error, :native_upgrade_not_available} ->
        {:noreply,
         socket
         |> assign(show_upgrade_modal: false)
         |> put_flash(
           :error,
           "Native systemd installation (/opt/hermit) not detected. Please upgrade via terminal using `hermit update`."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(show_upgrade_modal: false)
         |> put_flash(:error, "Failed to start upgrade: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:updater_status, new_status}, socket) do
    {:noreply, assign(socket, updater_status: new_status)}
  end

  defp get_system_info do
    {total_mem, _} = :erlang.memory(:total) |> format_bytes()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_str = format_uptime(uptime_ms)

    storage_base =
      System.get_env("STORAGE_BASE_PATH", Path.expand("storage", File.cwd!()))

    schedulers_online = :erlang.system_info(:schedulers_online)
    schedulers_total = :erlang.system_info(:schedulers)

    logical_cores =
      case :erlang.system_info(:logical_processors_online) do
        n when is_integer(n) -> n
        _ -> schedulers_total
      end

    erl_flags =
      System.get_env("ERL_AFLAGS") ||
        System.get_env("ERL_FLAGS", "+S #{schedulers_online}:#{schedulers_total}")

    %{
      elixir_version: System.version(),
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      memory_usage: total_mem,
      uptime: uptime_str,
      storage_base_path: storage_base,
      native_upgrade_available?: Updater.native_upgrade_available?(),
      schedulers_online: schedulers_online,
      schedulers_total: schedulers_total,
      logical_cores: logical_cores,
      erl_flags: erl_flags
    }
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    {"#{Float.round(bytes / 1_073_741_824, 2)} GB", bytes}
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    {"#{Float.round(bytes / 1_048_576, 2)} MB", bytes}
  end

  defp format_bytes(bytes) do
    {"#{Float.round(bytes / 1024, 2)} KB", bytes}
  end

  defp format_uptime(ms) do
    seconds = div(ms, 1000)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8 max-w-5xl mx-auto pb-12">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-base-300 pb-5">
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-base-content flex items-center gap-3">
            <.icon name="hero-cog-6-tooth" class="size-7 text-emerald-500" /> System & Updates
          </h1>
          <p class="text-xs text-base-content/60 mt-1">
            Manage native systemd service updates and runtime diagnostics.
          </p>
        </div>

        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="check_updates"
            class="btn btn-sm btn-outline border-base-300 hover:bg-base-200 text-xs gap-2"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Check for Updates
          </button>
        </div>
      </div>

      <!-- Upgrade Banner (If Update Available) -->
      <%= if @updater_status.update_available? do %>
        <div class="bg-gradient-to-r from-amber-500/10 via-amber-500/5 to-transparent border border-amber-500/30 rounded-xl p-6 relative overflow-hidden">
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <span class="badge badge-warning text-xs font-semibold px-2 py-0.5">UPDATE AVAILABLE</span>
                <span class="font-bold text-base text-base-content">
                  Hermit v{@updater_status.latest_version} is available!
                </span>
              </div>
              <p class="text-xs text-base-content/70">
                You are currently running <span class="font-mono font-medium">v{@updater_status.current_version}</span>. Upgrading takes ~10 seconds and preserves all configurations and tunnels.
              </p>
            </div>

            <div class="flex items-center gap-3 shrink-0">
              <%= if @updater_status.native_upgrade_available? do %>
                <button
                  type="button"
                  phx-click="open_upgrade_modal"
                  disabled={@updater_status.is_upgrading?}
                  class="btn btn-warning btn-sm text-xs font-bold gap-2 shadow-lg shadow-amber-500/20"
                >
                  <%= if @updater_status.is_upgrading? do %>
                    <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Upgrading...
                  <% else %>
                    <.icon name="hero-sparkles" class="size-4" />
                    Upgrade to v{@updater_status.latest_version}
                  <% end %>
                </button>
              <% else %>
                <a
                  href={@updater_status.release_url || "https://github.com/quaywin/hermit/releases"}
                  target="_blank"
                  class="btn btn-outline btn-warning btn-sm text-xs gap-1.5"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> View Release Notes
                </a>
              <% end %>
            </div>
          </div>

          <%= if @updater_status.release_notes && @updater_status.release_notes != "" do %>
            <div class="mt-4 pt-4 border-t border-amber-500/20">
              <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/60 block mb-2">
                Release Notes:
              </span>
              <div class="text-xs text-base-content/80 bg-base-100/60 rounded-lg p-3 max-h-40 overflow-y-auto whitespace-pre-wrap font-mono">
                {@updater_status.release_notes}
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Live Upgrading Status Alert -->
      <%= if @updater_status.is_upgrading? do %>
        <div class="alert alert-info shadow-lg border border-info/30">
          <.icon name="hero-arrow-path" class="size-6 animate-spin shrink-0 text-info" />
          <div>
            <h3 class="font-bold text-sm">Self-Upgrade in progress</h3>
            <div class="text-xs opacity-80">
              {@updater_status.upgrade_status ||
                "Downloading latest release archive and restarting hermit.service..."} The dashboard will automatically reconnect once rebooted.
            </div>
          </div>
        </div>
      <% end %>

      <!-- System Diagnostic Grid -->
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <!-- Version & Build Info Card -->
        <div class="card bg-base-100 border border-base-300 shadow-sm p-6 space-y-4">
          <h2 class="text-sm font-bold uppercase tracking-wider text-base-content/70 flex items-center gap-2">
            <.icon name="hero-tag" class="size-4 text-emerald-500" /> Software Version
          </h2>

          <div class="space-y-3">
            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">Current App Version</span>
              <span class="font-mono font-bold text-base-content">
                v{@updater_status.current_version}
              </span>
            </div>

            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">Latest Available Version</span>
              <span class="font-mono font-bold text-base-content">
                <%= if @updater_status.latest_version do %>
                  v{@updater_status.latest_version}
                <% else %>
                  <span class="text-base-content/40 font-normal">Not checked yet</span>
                <% end %>
              </span>
            </div>

            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">Native Auto-Upgrade</span>
              <%= if @system_info.native_upgrade_available? do %>
                <span class="badge badge-success badge-sm font-mono text-[10px] gap-1">
                  <.icon name="hero-check-circle" class="size-3" /> Ready (systemd)
                </span>
              <% else %>
                <span class="badge badge-ghost badge-sm font-mono text-[10px] gap-1">
                  <.icon name="hero-x-circle" class="size-3 text-warning" /> Unavailable
                </span>
              <% end %>
            </div>

            <div class="flex justify-between items-center py-2 text-xs">
              <span class="text-base-content/60">Last Checked</span>
              <span class="text-base-content/80 font-mono text-[11px]">
                <%= if @updater_status.checked_at do %>
                  {Calendar.strftime(@updater_status.checked_at, "%Y-%m-%d %H:%M:%S UTC")}
                <% else %>
                  Never
                <% end %>
              </span>
            </div>
          </div>
        </div>

        <!-- Runtime & Environment Card -->
        <div class="card bg-base-100 border border-base-300 shadow-sm p-6 space-y-4">
          <h2 class="text-sm font-bold uppercase tracking-wider text-base-content/70 flex items-center gap-2">
            <.icon name="hero-cpu-chip" class="size-4 text-emerald-500" /> Runtime Environment
          </h2>

          <div class="space-y-3">
            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">CPU Schedulers</span>
              <span class="font-mono font-bold text-base-content">
                {@system_info.schedulers_online} active / {@system_info.logical_cores} cores
                <span class="text-base-content/40 font-normal text-[10px]">({@system_info.erl_flags})</span>
              </span>
            </div>

            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">BEAM Memory Usage</span>
              <span class="font-mono font-bold text-base-content">
                {@system_info.memory_usage}
              </span>
            </div>

            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">Process Uptime</span>
              <span class="font-mono text-base-content">
                {@system_info.uptime}
              </span>
            </div>

            <div class="flex justify-between items-center py-2 border-b border-base-200 text-xs">
              <span class="text-base-content/60">Elixir / OTP</span>
              <span class="font-mono text-base-content">
                Elixir {@system_info.elixir_version} (OTP {@system_info.otp_release})
              </span>
            </div>

            <div class="flex justify-between items-center py-2 text-xs">
              <span class="text-base-content/60">Storage Path</span>
              <span
                class="font-mono text-base-content truncate max-w-[200px]"
                title={@system_info.storage_base_path}
              >
                {@system_info.storage_base_path}
              </span>
            </div>
          </div>
        </div>
      </div>

      <!-- Quick Command-line Upgrade Card -->
      <div class="card bg-base-100 border border-base-300 shadow-sm p-6 space-y-4">
        <h2 class="text-sm font-bold uppercase tracking-wider text-base-content/70 flex items-center gap-2">
          <.icon name="hero-command-line" class="size-4 text-emerald-500" /> Terminal Upgrade Command
        </h2>
        <p class="text-xs text-base-content/60">
          Alternatively, you can upgrade Hermit from your server terminal at any time:
        </p>
        <div class="bg-base-200/60 rounded-lg p-3 font-mono text-xs text-emerald-500 select-all border border-base-300">
          hermit update
        </div>
      </div>

      <!-- Confirmation Modal -->
      <%= if @show_upgrade_modal do %>
        <div class="modal modal-open">
          <div class="modal-box border border-base-300 shadow-2xl max-w-md">
            <h3 class="font-bold text-lg text-base-content flex items-center gap-2">
              <.icon name="hero-arrow-up-circle" class="size-6 text-warning" /> Confirm Self-Upgrade
            </h3>

            <div class="py-4 space-y-3 text-xs text-base-content/80">
              <p>
                Hermit will download the latest native release archive, switch <span class="font-mono font-bold text-emerald-500">/opt/hermit/current</span>,
                and restart <span class="font-mono font-bold">hermit.service</span>.
              </p>
              <ul class="list-disc list-inside space-y-1 text-base-content/70">
                <li>
                  Database and configuration files in <span class="font-mono">/var/lib/hermit</span>
                  and <span class="font-mono">/etc/hermit/env</span>
                  remain preserved.
                </li>
                <li>Active VPN tunnels and DNS nodes will cleanly re-establish after restart.</li>
                <li>The web interface will automatically reconnect in ~5–10 seconds.</li>
              </ul>
            </div>

            <div class="modal-action">
              <button
                type="button"
                phx-click="close_upgrade_modal"
                class="btn btn-sm btn-ghost text-xs"
              >
                Cancel
              </button>
              <button
                type="button"
                phx-click="confirm_upgrade"
                class="btn btn-sm btn-warning text-xs font-bold gap-2"
              >
                <.icon name="hero-bolt" class="size-4" /> Proceed with Upgrade
              </button>
            </div>
          </div>
          <div class="modal-backdrop bg-black/60" phx-click="close_upgrade_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end
end
