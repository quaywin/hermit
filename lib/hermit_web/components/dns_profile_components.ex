defmodule HermitWeb.DnsProfileComponents do
  @moduledoc """
  Functional components for `HermitWeb.DnsProfileLive`.
  """
  use HermitWeb, :html

  attr :selected_profile, :map, required: true
  attr :editing_name, :boolean, required: true
  attr :name_form, :any, required: true

  def profile_header_card(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-[12px] p-6 shadow-sm flex items-center justify-between flex-wrap gap-4">
      <div class="flex-1 min-w-[280px]">
        <%= if @editing_name do %>
          <.form
            id="edit-profile-name-form"
            for={@name_form}
            phx-submit="save_name"
            class="flex items-center gap-2 max-w-md"
          >
            <div class="flex-1">
              <.input
                field={@name_form[:name]}
                type="text"
                required
                class="w-full bg-base-200 border border-base-300 rounded-[6px] px-3 py-1.5 text-xs font-semibold focus:outline-none focus:border-primary"
              />
            </div>
            <button
              type="submit"
              class="btn btn-primary btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px] cursor-pointer"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel_edit_name"
              class="btn btn-outline btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px] cursor-pointer"
            >
              Cancel
            </button>
          </.form>
        <% else %>
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content">
              DNS Profile: {@selected_profile.name}
            </h2>
            <button
              type="button"
              phx-click="start_edit_name"
              class="text-base-content/50 hover:text-base-content cursor-pointer transition-colors"
              title="Rename Profile"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
          </div>
          <p class="text-xs text-base-content/60 mt-0.5">
            Configure upstream servers, security filter levels and domain rules for this profile.
          </p>
        <% end %>
      </div>
      <button
        phx-click="delete_profile"
        phx-value-id={@selected_profile.id}
        data-confirm="Are you sure you want to delete this DNS Profile?"
        class="btn btn-error btn-outline btn-xs uppercase tracking-wider text-[10px] rounded-[4px] cursor-pointer"
      >
        Delete Profile
      </button>
    </div>
    """
  end

  attr :selected_profile, :map, required: true
  attr :available_blocklists, :list, required: true

  def blocklist_filters_card(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-[12px] p-4 shadow-sm">
      <div class="flex flex-col lg:flex-row lg:items-center justify-between gap-4">
        <div class="flex items-center gap-2">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 shrink-0">
            Security & Ad-Blocking Filters
          </h2>
          <.link
            navigate={~p"/dns/blocklists"}
            class="text-[10px] text-emerald-500 hover:text-emerald-600 font-semibold underline"
          >
            (Manage Sources)
          </.link>
        </div>
        <div class="flex flex-wrap items-center gap-3">
          <%= if @available_blocklists == [] do %>
            <span class="text-xs text-base-content/40 italic">
              No active blocklist filters configured.
            </span>
          <% else %>
            <%= for blocklist <- @available_blocklists do %>
              <% active =
                Enum.any?(@selected_profile.blocklists || [], &(&1.id == blocklist.id)) %>
              <div
                class="px-3 py-1.5 bg-base-200/30 rounded-[8px] border border-base-300/50 flex items-center gap-3 cursor-help transition-all hover:bg-base-200/50"
                title={blocklist.description || "Blocks domains matching this filter source."}
              >
                <span class="text-[10px] sm:text-xs font-semibold uppercase tracking-wider text-base-content/85">
                  {blocklist.name}
                </span>
                <button
                  phx-click="toggle_profile_blocklist"
                  phx-value-blocklist-id={blocklist.id}
                  class={[
                    "btn btn-xs rounded-[4px] font-semibold uppercase tracking-wider",
                    if(active, do: "btn-primary", else: "btn-outline")
                  ]}
                >
                  {if active, do: "Blocking", else: "Allowing"}
                </button>
              </div>
            <% end %>
          <% end %>

          <!-- IPv6 (AAAA) Filter -->
          <div
            class="px-3 py-1.5 bg-base-200/30 rounded-[8px] border border-base-300/50 flex items-center gap-3 cursor-help transition-all hover:bg-base-200/50"
            title="Blocks IPv6 AAAA requests. Improves speed and prevents IPv6 leaks."
          >
            <span class="text-[10px] sm:text-xs font-semibold uppercase tracking-wider text-base-content/85">
              IPv6
            </span>
            <button
              phx-click="toggle_block_ipv6"
              class={[
                "btn btn-xs rounded-[4px] font-semibold uppercase tracking-wider",
                if(@selected_profile.block_ipv6, do: "btn-primary", else: "btn-outline")
              ]}
            >
              {if @selected_profile.block_ipv6, do: "Blocking", else: "Allowing"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :selected_profile, :map, required: true

  def upstream_and_policies_card(assigns) do
    ~H"""
    <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
      <!-- Upstream Servers -->
      <div class="bg-base-100 border border-base-300 rounded-[12px] p-6 shadow-sm flex flex-col justify-between">
        <div class="space-y-6">
          <div>
            <div class="flex items-center justify-between mb-1">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Upstream DNS Servers
              </h3>
              <!-- EDNS Client Subnet (ECS) Toggle -->
              <button
                phx-click="toggle_enable_ecs"
                class={[
                  "btn btn-xs rounded-[4px] font-semibold uppercase tracking-wider",
                  if(@selected_profile.enable_ecs, do: "btn-primary", else: "btn-outline")
                ]}
                title="Sends EDNS Client Subnet to upstream DNS to optimize CDN routing (e.g. YouTube, Netflix)."
              >
                {if @selected_profile.enable_ecs, do: "ECS Active", else: "ECS Inactive"}
              </button>
            </div>
            <p class="text-[11px] text-base-content/50 mb-4">
              Support legacy DNS IPs (53) or HTTPS DoH URLs (e.g. <code>https://cloudflare-dns.com/dns-query</code>).
            </p>
            <form id="save-upstream-dns-form" phx-submit="save_upstream_dns" class="space-y-4">
              <input
                type="text"
                name="upstream_dns"
                value={@selected_profile.upstream_dns}
                placeholder="e.g. 1.1.1.1, 8.8.8.8, https://dns.google/dns-query"
                class="w-full bg-base-200 border border-base-300 rounded-[6px] px-3 py-2 text-xs font-mono placeholder:text-base-content/30 focus:outline-none focus:border-primary"
              />
              <button
                type="submit"
                class="btn btn-primary btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px]"
              >
                Save Upstream
              </button>
            </form>
          </div>

          <%= if @selected_profile.enable_ecs do %>
            <div class="border-t border-base-300/50 pt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-1">
                EDNS Client Subnet (ECS) Fallback IP
              </h3>
              <p class="text-[11px] text-base-content/50 mb-4">
                Optional. Used when the client IP is private (Tailscale, LAN). Allows public resolvers to locate CDNs in your target country (e.g. Vietnam).
              </p>
              <form
                id="save-ecs-fallback-ip-form"
                phx-submit="save_ecs_fallback_ip"
                class="space-y-4"
              >
                <input
                  type="text"
                  name="ecs_fallback_ip"
                  value={@selected_profile.ecs_fallback_ip}
                  placeholder="e.g. 14.162.50.1 (FPT), 113.160.0.1 (VNPT)"
                  class="w-full bg-base-200 border border-base-300 rounded-[6px] px-3 py-2 text-xs font-mono placeholder:text-base-content/30 focus:outline-none focus:border-primary"
                />
                <button
                  type="submit"
                  class="btn btn-primary btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px]"
                >
                  Save Fallback IP
                </button>
              </form>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Smart DNS & Domain Policies Summary -->
      <div class="bg-base-100 border border-base-300 rounded-[12px] p-6 shadow-sm flex flex-col justify-between space-y-6">
        <div>
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Routing & Domain Policies
            </h3>
            <span class="text-[10px] text-emerald-500 font-semibold bg-emerald-500/10 px-2 py-0.5 rounded-[4px] border border-emerald-500/20">
              Control D Model
            </span>
          </div>
          <p class="text-[11px] text-base-content/60 mb-4">
            Configure smart split-tunneling presets for streaming/AI platforms or granular rules for individual domains.
          </p>

          <!-- Stats & Links Grid -->
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4">
            <!-- Services Quick Box -->
            <% services_count = map_size(@selected_profile.services || %{}) %>
            <div class="p-3 bg-base-200/40 rounded-[8px] border border-base-300/60 flex flex-col justify-between">
              <div>
                <div class="flex items-center justify-between mb-1">
                  <span class="text-xs font-semibold text-base-content">Services Catalog</span>
                  <.icon name="hero-sparkles" class="size-4 text-emerald-500" />
                </div>
                <p class="text-[10px] text-base-content/50">
                  Netflix, OpenAI, Claude, Disney+, etc.
                </p>
              </div>
              <div class="mt-3 flex items-center justify-between">
                <span class="text-xs font-mono font-bold text-base-content">
                  {services_count} configured
                </span>
                <.link
                  navigate={~p"/dns/services?profile_id=#{@selected_profile.id}"}
                  class="text-xs font-semibold text-emerald-500 hover:text-emerald-600 underline"
                >
                  Manage &rarr;
                </.link>
              </div>
            </div>

            <!-- Custom Rules Quick Box -->
            <% rules_count = length(@selected_profile.custom_rules || []) %>
            <div class="p-3 bg-base-200/40 rounded-[8px] border border-base-300/60 flex flex-col justify-between">
              <div>
                <div class="flex items-center justify-between mb-1">
                  <span class="text-xs font-semibold text-base-content">Custom Rules</span>
                  <.icon name="hero-list-bullet" class="size-4 text-primary" />
                </div>
                <p class="text-[10px] text-base-content/50">
                  FQDN & wildcard domain overrides
                </p>
              </div>
              <div class="mt-3 flex items-center justify-between">
                <span class="text-xs font-mono font-bold text-base-content">
                  {rules_count} rules
                </span>
                <.link
                  navigate={~p"/dns/rules"}
                  class="text-xs font-semibold text-emerald-500 hover:text-emerald-600 underline"
                >
                  Manage &rarr;
                </.link>
              </div>
            </div>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2 pt-2 border-t border-base-300/50">
          <.link
            navigate={~p"/dns/services"}
            class="btn btn-primary btn-xs uppercase tracking-wider px-3 py-1.5 rounded-[4px] flex items-center gap-1.5"
          >
            <.icon name="hero-sparkles" class="size-3.5" /> Open Services Catalog
          </.link>
          <.link
            navigate={~p"/dns/rules"}
            class="btn btn-outline btn-xs uppercase tracking-wider px-3 py-1.5 rounded-[4px] flex items-center gap-1.5"
          >
            <.icon name="hero-list-bullet" class="size-3.5" /> Open Domain Rules
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :selected_profile, :map, required: true
  attr :dns_metrics, :map, required: true
  attr :time_range, :string, required: true

  def resolution_metrics_card(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-[12px] p-6 shadow-sm">
      <div class="flex items-center justify-between border-b border-base-300 pb-2 mb-4">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          DNS Resolution Analytics
        </h2>

        <!-- Tab Chọn Khoảng Thời Gian -->
        <div class="flex bg-base-200 p-0.5 rounded-[6px] text-[10px] font-semibold border border-base-300/40">
          <button
            phx-click="change_time_range"
            phx-value-range="1h"
            class={[
              "px-2.5 py-1 rounded-[4px] uppercase transition-all duration-200 cursor-pointer",
              if(@time_range == "1h",
                do: "bg-base-100 text-base-content shadow-sm",
                else: "text-base-content/40 hover:text-base-content/70"
              )
            ]}
          >
            1 Hour
          </button>
          <button
            phx-click="change_time_range"
            phx-value-range="24h"
            class={[
              "px-2.5 py-1 rounded-[4px] uppercase transition-all duration-200 cursor-pointer",
              if(@time_range == "24h",
                do: "bg-base-100 text-base-content shadow-sm",
                else: "text-base-content/40 hover:text-base-content/70"
              )
            ]}
          >
            24 Hours
          </button>
          <button
            phx-click="change_time_range"
            phx-value-range="7d"
            class={[
              "px-2.5 py-1 rounded-[4px] uppercase transition-all duration-200 cursor-pointer",
              if(@time_range == "7d",
                do: "bg-base-100 text-base-content shadow-sm",
                else: "text-base-content/40 hover:text-base-content/70"
              )
            ]}
          >
            7 Days
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <!-- Box 1: Ad-Block Efficiency -->
        <div class="p-4 bg-base-200/30 rounded-[8px] border border-base-300/50 flex flex-col justify-between min-h-[110px]">
          <div class="flex items-center justify-between border-b border-base-300/30 pb-2">
            <span class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
              Ad-Block Efficiency
            </span>
            <span class="text-[9px] font-bold uppercase text-emerald-500 bg-emerald-500/10 px-1.5 py-0.2 rounded border border-emerald-500/20">
              Active
            </span>
          </div>
          <div class="my-2.5">
            <span class="text-2xl font-bold tracking-tight text-emerald-500">
              {@dns_metrics.block_rate}%
            </span>
            <div class="w-full bg-base-300/50 rounded-full h-1 mt-1.5 overflow-hidden">
              <div
                class="bg-emerald-500 h-full rounded-full"
                style={"width: #{@dns_metrics.block_rate}%"}
              >
              </div>
            </div>
          </div>
          <div class="text-[10px] text-base-content/40">
            Est. Data Saved:
            <strong class="text-emerald-500 font-mono font-semibold">
              {@dns_metrics.data_saved}
            </strong>
          </div>
        </div>

        <!-- Box 2: Served Queries -->
        <div class="p-4 bg-base-200/30 rounded-[8px] border border-base-300/50 flex flex-col justify-between min-h-[110px]">
          <div class="flex items-center justify-between border-b border-base-300/30 pb-2">
            <span class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
              Served Queries
            </span>
            <.icon name="hero-bolt" class="size-3.5 text-amber-500" />
          </div>
          <div class="my-2">
            <span class="text-2xl font-bold tracking-tight text-base-content">
              {@dns_metrics.total}
            </span>
            <span class="text-[10px] text-base-content/40 ml-1">total requests</span>
          </div>
          <div class="text-[10px] text-base-content/40">
            Total Blocked:
            <strong class="text-base-content font-mono font-semibold">
              {@dns_metrics.blocked}
            </strong>
          </div>
        </div>

        <!-- Box 3: IPv6 Leak Protection -->
        <div class="p-4 bg-base-200/30 rounded-[8px] border border-base-300/50 flex flex-col justify-between min-h-[110px]">
          <div class="flex items-center justify-between border-b border-base-300/30 pb-2">
            <span class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
              IPv6 Leak Protection
            </span>
            <%= if @selected_profile.block_ipv6 do %>
              <span class="text-[9px] font-bold uppercase text-indigo-500 bg-indigo-500/10 px-1.5 py-0.2 rounded border border-indigo-500/20">
                Secure
              </span>
            <% else %>
              <span class="text-[9px] font-bold uppercase text-base-content/40 bg-base-300 px-1.5 py-0.2 rounded">
                Disabled
              </span>
            <% end %>
          </div>
          <div class="my-2">
            <span class="text-2xl font-bold tracking-tight text-indigo-500">
              {@dns_metrics.ipv6_blocked_count}
            </span>
            <span class="text-[10px] text-base-content/40 ml-1">leaks blocked</span>
          </div>
          <div class="text-[10px] text-base-content/40">
            Status:
            <strong class="text-base-content font-semibold">
              {if @selected_profile.block_ipv6,
                do: "Blocking AAAA",
                else: "IPv6 Allowed"}
            </strong>
          </div>
        </div>
      </div>

      <!-- Divider Line -->
      <div class="border-t border-base-300/40 my-4.5"></div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <!-- Left: Top Blocked Domains -->
        <div class="p-4 bg-base-200/20 rounded-[8px] border border-base-300/40 flex flex-col justify-between min-h-[150px]">
          <div class="flex items-center justify-between border-b border-base-300/20 pb-2 mb-3">
            <span class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
              Top Blocked Domains
            </span>
            <.icon name="hero-bug-ant" class="size-3.5 text-amber-500/80" />
          </div>
          <div class="flex-1 flex flex-col justify-center">
            <%= if @dns_metrics.top_blocked == [] do %>
              <p class="text-[10px] text-base-content/40 italic text-center py-4">
                No trackers blocked yet.
              </p>
            <% else %>
              <ul class="space-y-2 text-[10px] font-mono leading-normal">
                <li
                  :for={tracker <- @dns_metrics.top_blocked}
                  class="flex items-center justify-between py-1 border-b border-base-300/10 last:border-0"
                >
                  <span
                    class="truncate max-w-[200px] text-base-content/75 font-medium"
                    title={tracker.domain}
                  >
                    {tracker.domain}
                  </span>
                  <span class="px-1.5 py-0.5 bg-base-200/60 text-base-content/70 rounded-[4px] font-sans font-bold">
                    {tracker.count}
                  </span>
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <!-- Right: Filter Efficiency Breakdown -->
        <div class="p-4 bg-base-200/20 rounded-[8px] border border-base-300/40 flex flex-col justify-between min-h-[150px]">
          <div class="flex items-center justify-between border-b border-base-300/20 pb-2 mb-3">
            <span class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
              Filter Source Efficiency
            </span>
            <.icon name="hero-funnel" class="size-3.5 text-indigo-500/80" />
          </div>

          <div class="flex-1 flex flex-col justify-center space-y-2.5">
            <%= if @dns_metrics.blocked == 0 do %>
              <p class="text-[10px] text-base-content/40 italic text-center py-4">
                No blocking actions recorded.
              </p>
            <% else %>
              <% total_blocked_in_blocklists =
                Enum.sum(Map.values(@dns_metrics.blocklist_breakdown || %{})) %>
              <!-- Dynamic Enabled Blocklists -->
              <%= for blocklist <- @selected_profile.blocklists || [] do %>
                <% name_lc = String.downcase(blocklist.name)
                count = Map.get(@dns_metrics.blocklist_breakdown || %{}, blocklist.id, 0)

                color =
                  cond do
                    String.contains?(name_lc, "goodbye") -> "bg-amber-500"
                    String.contains?(name_lc, "adult") -> "bg-red-500"
                    true -> "bg-emerald-500"
                  end %>
                <div class="space-y-1">
                  <div class="flex items-center justify-between text-[10px]">
                    <span class="text-base-content/70 font-medium">{blocklist.name}</span>
                    <span class="font-bold font-mono">{count}</span>
                  </div>
                  <div class="w-full bg-base-300/40 rounded-full h-1 overflow-hidden">
                    <div
                      class={["h-full rounded-full", color]}
                      style={"width: #{if total_blocked_in_blocklists > 0, do: (count / total_blocked_in_blocklists * 100), else: 0}%"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>

              <!-- Custom Block Rules -->
              <div class="space-y-1">
                <div class="flex items-center justify-between text-[10px]">
                  <span class="text-base-content/70 font-medium">Custom Rules</span>
                  <span class="font-bold font-mono">{@dns_metrics.custom_blocked_count}</span>
                </div>
                <div class="w-full bg-base-300/40 rounded-full h-1 overflow-hidden">
                  <div
                    class="bg-blue-500 h-full rounded-full"
                    style={"width: #{if @dns_metrics.blocked > 0, do: (@dns_metrics.custom_blocked_count / @dns_metrics.blocked * 100), else: 0}%"}
                  >
                  </div>
                </div>
              </div>

              <!-- IPv6 Block Filter (Show only if enabled) -->
              <%= if @selected_profile.block_ipv6 do %>
                <div class="space-y-1">
                  <div class="flex items-center justify-between text-[10px]">
                    <span class="text-base-content/70 font-medium">IPv6 Leak Filter</span>
                    <span class="font-bold font-mono">{@dns_metrics.ipv6_blocked_count}</span>
                  </div>
                  <div class="w-full bg-base-300/40 rounded-full h-1 overflow-hidden">
                    <div
                      class="bg-indigo-500 h-full rounded-full"
                      style={"width: #{if @dns_metrics.blocked > 0, do: (@dns_metrics.ipv6_blocked_count / @dns_metrics.blocked * 100), else: 0}%"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :create_form, :any, required: true

  def create_profile_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4">
        <div class="bg-base-100 border border-base-300 rounded-[12px] w-full max-w-md shadow-2xl overflow-hidden animate-in fade-in-50 zoom-in-95 duration-200">
          <header class="h-14 flex items-center justify-between px-6 border-b border-base-300">
            <span class="font-bold text-sm uppercase tracking-wider text-base-content">
              Create DNS Profile
            </span>
            <button
              phx-click="close_create_modal"
              class="text-base-content/50 hover:text-base-content cursor-pointer"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <.form
            id="create-dns-profile-form"
            for={@create_form}
            phx-change="validate_create"
            phx-submit="save_profile"
            class="p-6 space-y-4"
          >
            <div class="space-y-1">
              <label class="text-xs font-semibold uppercase text-base-content/60 block">
                Profile Name
              </label>
              <.input
                field={@create_form[:name]}
                placeholder="e.g. Home Ad-Blocker, Kids Protection"
                required
                class="w-full bg-base-200 border border-base-300 rounded-[6px] px-3 py-2 text-xs focus:outline-none"
              />
            </div>

            <div class="space-y-1">
              <label class="text-xs font-semibold uppercase text-base-content/60 block">
                Upstream DNS Servers
              </label>
              <.input
                field={@create_form[:upstream_dns]}
                placeholder="e.g. 1.1.1.1, 8.8.8.8"
                required
                class="w-full bg-base-200 border border-base-300 rounded-[6px] px-3 py-2 text-xs focus:outline-none"
              />
            </div>

            <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300/60 mt-6">
              <button
                type="button"
                phx-click="close_create_modal"
                class="btn btn-outline btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px] cursor-pointer"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={not @create_form.source.valid?}
                class="btn btn-primary btn-xs uppercase tracking-wider px-3 py-2 rounded-[4px] cursor-pointer"
              >
                Create
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>
    """
  end
end
