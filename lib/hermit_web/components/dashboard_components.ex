defmodule HermitWeb.DashboardComponents do
  @moduledoc """
  Functional components for the System Overview Dashboard LiveView.
  """
  use HermitWeb, :html

  attr :dns_summary, :map, required: true
  attr :active_tunnels, :integer, required: true
  attr :active_endpoints, :integer, required: true
  attr :total_endpoints, :integer, required: true

  def kpi_overview(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <div class="bg-base-100 border border-base-300 rounded-[12px] p-5 shadow-sm flex items-center justify-between">
        <div>
          <span class="text-xs font-medium uppercase tracking-wider text-base-content/60">
            24h DNS Queries
          </span>
          <div class="text-2xl font-bold font-mono text-base-content mt-1">
            {Hermit.format_number(@dns_summary.total_queries)}
          </div>
          <span class="text-[11px] text-base-content/50">Total queries resolved</span>
        </div>
        <div class="p-3 rounded-full bg-emerald-500/10 text-emerald-500 border border-emerald-500/20">
          <.icon name="hero-globe-alt" class="size-6" />
        </div>
      </div>

      <div class="bg-base-100 border border-base-300 rounded-[12px] p-5 shadow-sm flex items-center justify-between">
        <div>
          <span class="text-xs font-medium uppercase tracking-wider text-base-content/60">
            Blocked Threats
          </span>
          <div class="text-2xl font-bold font-mono text-rose-500 mt-1">
            {Hermit.format_number(@dns_summary.blocked_queries)}
          </div>
          <span class="text-[11px] text-base-content/50">Ads & malicious domains</span>
        </div>
        <div class="p-3 rounded-full bg-rose-500/10 text-rose-500 border border-rose-500/20">
          <.icon name="hero-shield-check" class="size-6" />
        </div>
      </div>

      <div class="bg-base-100 border border-base-300 rounded-[12px] p-5 shadow-sm flex items-center justify-between">
        <div>
          <span class="text-xs font-medium uppercase tracking-wider text-base-content/60">
            Protection Rate
          </span>
          <div class="text-2xl font-bold font-mono text-base-content mt-1 flex items-baseline gap-2">
            <span>{@dns_summary.block_rate}%</span>
            <%= if @dns_summary.block_rate > 0 do %>
              <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-600 border border-emerald-500/20 font-sans">
                Active
              </span>
            <% else %>
              <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-base-200 text-base-content/50 border border-base-300 font-sans">
                Clean
              </span>
            <% end %>
          </div>
          <span class="text-[11px] text-base-content/50">Ratio of blocked queries</span>
        </div>
        <div class="p-3 rounded-full bg-blue-500/10 text-blue-500 border border-blue-500/20">
          <.icon name="hero-chart-pie" class="size-6" />
        </div>
      </div>

      <div class="bg-base-100 border border-base-300 rounded-[12px] p-5 shadow-sm flex items-center justify-between">
        <div>
          <span class="text-xs font-medium uppercase tracking-wider text-base-content/60">
            Active Services
          </span>
          <div class="text-2xl font-bold font-mono text-base-content mt-1">
            {@active_tunnels}
            <span class="text-sm font-normal text-base-content/50 font-sans">Tunnels</span>
          </div>
          <span class="text-[11px] text-base-content/50">
            {@active_endpoints} / {@total_endpoints} Endpoints online
          </span>
        </div>
        <div class="p-3 rounded-full bg-amber-500/10 text-amber-500 border border-amber-500/20">
          <.icon name="hero-server-stack" class="size-6" />
        </div>
      </div>
    </div>
    """
  end

  attr :hourly_series, :list, required: true

  def dns_activity_chart(assigns) do
    max_queries = Enum.reduce(assigns.hourly_series, 1, fn h, acc -> max(acc, h.total) end)
    assigns = assign(assigns, :max_queries, max_queries)

    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-[12px] p-6 shadow-sm">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between pb-4 border-b border-base-300/60 gap-2">
        <div>
          <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content">
            24-Hour Query Volume & Protection Activity
          </h2>
          <p class="text-xs text-base-content/50 mt-0.5">
            Hourly breakdown of queries processed vs blocked domains
          </p>
        </div>
        <div class="flex items-center gap-4 text-xs font-medium text-base-content/70">
          <div class="flex items-center gap-1.5">
            <span class="size-2.5 rounded-sm bg-emerald-500"></span>
            <span>Allowed Queries</span>
          </div>
          <div class="flex items-center gap-1.5">
            <span class="size-2.5 rounded-sm bg-rose-500"></span>
            <span>Blocked Queries</span>
          </div>
        </div>
      </div>

      <div class="pt-6">
        <div class="h-36 flex items-end gap-1 sm:gap-1.5 px-1 border-b border-base-300">
          <%= for {point, _idx} <- Enum.with_index(@hourly_series) do %>
            <% height_pct =
              if point.total > 0, do: max(6, round(point.total / @max_queries * 100)), else: 3 %>
            <% blocked_ratio =
              if point.total > 0, do: min(100, round(point.blocked / point.total * 100)), else: 0 %>
            <div class="flex-1 flex flex-col justify-end items-center h-full group relative cursor-pointer">
              <div class="opacity-0 group-hover:opacity-100 transition-opacity absolute bottom-full mb-2 z-20 pointer-events-none bg-base-300 text-base-content text-[11px] font-mono px-2.5 py-1.5 rounded-[6px] shadow-lg border border-base-content/10 whitespace-nowrap">
                <div class="font-bold">{point.hour_label}</div>
                <div class="text-emerald-500">
                  Allowed: {Hermit.format_number(point.total - point.blocked)}
                </div>
                <div class="text-rose-500">
                  Blocked: {Hermit.format_number(point.blocked)} ({blocked_ratio}%)
                </div>
                <div class="text-base-content/60 text-[10px] mt-0.5">
                  Total: {Hermit.format_number(point.total)}
                </div>
              </div>

              <div
                style={"height: #{height_pct}%;"}
                class="w-full max-w-[28px] rounded-t-[3px] overflow-hidden flex flex-col-reverse transition-all duration-300 group-hover:brightness-110"
              >
                <div
                  style={"height: #{100 - blocked_ratio}%;"}
                  class="w-full bg-emerald-500/80 group-hover:bg-emerald-500"
                >
                </div>
                <%= if point.blocked > 0 do %>
                  <div
                    style={"height: #{blocked_ratio}%;"}
                    class="w-full bg-rose-500/80 group-hover:bg-rose-500"
                  >
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <div class="flex items-center justify-between text-[10px] font-mono text-base-content/50 pt-2 px-1">
          <%= for {point, idx} <- Enum.with_index(@hourly_series) do %>
            <div class={"flex-1 text-center #{if rem(idx, 4) != 0 and idx != 23, do: "hidden sm:hidden md:block opacity-0", else: ""}"}>
              {point.hour_label}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :error_tunnels, :list, required: true

  def error_tunnels_banner(assigns) do
    ~H"""
    <div class="bg-red-500/10 border border-red-500/30 rounded-[12px] p-4 text-sm text-base-content space-y-3 shadow-sm">
      <div class="flex items-center gap-2 font-semibold text-red-500">
        <.icon name="hero-exclamation-triangle" class="size-5 text-red-500 shrink-0" />
        <span>{length(@error_tunnels)} VPN Tunnel(s) encountered errors and need attention:</span>
      </div>
      <div class="space-y-2">
        <%= for tunnel <- @error_tunnels do %>
          <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2 p-3 bg-base-100 rounded-[8px] border border-red-500/20">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <span class="font-mono font-bold text-base-content">{tunnel.id}</span>
                <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-semibold bg-red-500/10 text-red-500 border border-red-500/20">
                  <span class="w-1.5 h-1.5 rounded-full bg-red-500"></span> Error
                </span>
              </div>
              <div class="text-xs text-red-500 font-medium">
                {tunnel.ts_error_reason || tunnel.wg_error_reason || "Connection Error"}
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <%= if tunnel.ts_status == :error and Map.get(tunnel, :inbound_profile_id) do %>
                <.link
                  navigate={~p"/inbounds/#{Map.get(tunnel, :inbound_profile_id)}?tab=config"}
                  class="btn btn-xs btn-error text-white font-medium text-xs"
                >
                  Update Inbound Key
                </.link>
              <% end %>
              <%= if tunnel.wg_status == :error and Map.get(tunnel, :outbound_profile_id) do %>
                <.link
                  navigate={~p"/outbounds/#{Map.get(tunnel, :outbound_profile_id)}?tab=config"}
                  class="btn btn-xs btn-warning text-white font-medium text-xs"
                >
                  Check Outbound
                </.link>
              <% end %>
              <.link
                navigate={~p"/tunnels/#{tunnel.id}"}
                class="btn btn-xs btn-ghost border border-base-300 font-medium text-xs"
              >
                View Details
              </.link>
              <button
                phx-click="restart_tunnel"
                phx-value-id={tunnel.id}
                class="btn btn-xs btn-primary font-medium text-xs"
              >
                Restart
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :inbound_profiles, :list, required: true
  attr :outbound_profiles, :list, required: true

  def deploy_tunnel_modal(assigns) do
    ~H"""
    <dialog id="deploy-tunnel-modal" class="modal modal-open z-50 backdrop-blur-sm">
      <div class="modal-box w-full max-w-lg bg-base-100 border border-base-300 p-6 space-y-4 text-base-content rounded-[16px]">
        <div class="flex items-center justify-between border-b border-base-300 pb-3">
          <h3 class="text-lg font-medium text-base-content flex items-center gap-2">
            🚀 Deploy New VPN Tunnel
          </h3>
          <button
            type="button"
            phx-click="close_create_modal"
            class="text-base-content/60 hover:text-base-content transition-colors cursor-pointer"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <p class="text-xs text-base-content/60">
          Link an isolated inbound network interface SOCKS5/Tailscale to an outbound Wireguard gateway.
        </p>

        <%= if Enum.empty?(@inbound_profiles) or Enum.empty?(@outbound_profiles) do %>
          <div class="bg-amber-500/10 border border-amber-500/30 rounded-[10px] p-3.5 text-xs space-y-2">
            <div class="font-semibold text-amber-500 flex items-center gap-1.5">
              <.icon name="hero-information-circle" class="size-4 shrink-0" />
              <span>Setup Required Before Deploying:</span>
            </div>
            <p class="text-base-content/80 leading-relaxed text-[11px]">
              A tunnel requires at least one <strong>Inbound Profile</strong>
              (client ingress) and one <strong>Outbound Profile</strong>
              (egress gateway):
            </p>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 pt-1">
              <%= if Enum.empty?(@inbound_profiles) do %>
                <.link
                  navigate={~p"/inbounds"}
                  class="btn btn-xs btn-outline btn-warning gap-1.5 justify-start text-[11px]"
                >
                  <.icon name="hero-plus" class="size-3" /> Create Inbound Profile
                </.link>
              <% else %>
                <div class="flex items-center gap-1 text-emerald-500 font-medium text-[11px] py-0.5">
                  <.icon name="hero-check-circle" class="size-3.5" /> Inbound Ready
                </div>
              <% end %>

              <%= if Enum.empty?(@outbound_profiles) do %>
                <.link
                  navigate={~p"/outbounds"}
                  class="btn btn-xs btn-outline btn-warning gap-1.5 justify-start text-[11px]"
                >
                  <.icon name="hero-plus" class="size-3" /> Create Outbound Profile
                </.link>
              <% else %>
                <div class="flex items-center gap-1 text-emerald-500 font-medium text-[11px] py-0.5">
                  <.icon name="hero-check-circle" class="size-3.5" /> Outbound Ready
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <.form
          :let={f}
          for={@form}
          phx-change="validate"
          phx-submit="save"
          id="vpn-pair-form"
          class="space-y-4"
        >
          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              Tunnel ID / Name
            </label>
            <.input
              field={f[:pair_id]}
              type="text"
              placeholder="e.g., prod_us_east"
              class="w-full input input-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content font-mono text-sm rounded-[4px]"
            />
          </div>

          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              Inbound Profile
            </label>
            <.input
              field={f[:inbound_profile_id]}
              type="select"
              prompt="Select an Inbound Profile"
              options={Enum.map(@inbound_profiles, &{&1.name, &1.id})}
              class="w-full select select-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content text-sm rounded-[4px]"
            />
          </div>

          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              Outbound Profile
            </label>
            <.input
              field={f[:outbound_profile_id]}
              type="select"
              prompt="Select an Outbound Profile"
              options={Enum.map(@outbound_profiles, &{&1.name, &1.id})}
              class="w-full select select-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content text-sm rounded-[4px]"
            />
          </div>

          <div class="flex justify-end gap-3 pt-4 border-t border-base-300">
            <button
              type="button"
              phx-click="close_create_modal"
              class="btn btn-outline-custom px-4 py-2 rounded-[6px] text-xs font-medium uppercase tracking-wider cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary px-4 py-2 rounded-[6px] text-xs font-medium uppercase tracking-wider cursor-pointer"
            >
              Spawn VPN Pair
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end
end
