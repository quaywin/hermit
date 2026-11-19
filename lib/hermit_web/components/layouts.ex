defmodule HermitWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HermitWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current scope"

  def app(assigns) do
    assigns =
      assigns
      |> assign(:active, active_route(assigns))
      |> assign(:updater_info, Hermit.Updater.status())

    ~H"""
    <div class="flex h-screen w-screen overflow-hidden bg-base-100 text-base-content font-sans antialiased">
      <!-- Desktop Sidebar -->
      <aside class="hidden lg:flex w-64 bg-base-100 border-r border-base-300 flex-col justify-between shrink-0 h-full">
        <div class="flex flex-col overflow-y-auto">
          <!-- Logo / Header -->
          <div class="h-16 flex items-center px-6 border-b border-base-300 shrink-0">
            <.link navigate={~p"/"} class="flex items-center gap-2">
              <img src={~p"/images/logo.png"} width="30" />
              <span class="font-bold text-lg tracking-wider uppercase text-base-content">Hermit</span>
            </.link>
          </div>

          <.nav_menu active={@active} />
        </div>

        <!-- Sidebar Footer -->
        <div class="p-4 border-t border-base-300 space-y-2 bg-base-100 shrink-0">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="text-[10px] text-base-content/50 font-mono">
                v{@updater_info.current_version}
              </span>
              <%= if @updater_info.update_available? do %>
                <.link
                  navigate={~p"/settings"}
                  class="badge badge-warning badge-xs font-mono text-[9px] gap-1 animate-pulse hover:opacity-80"
                >
                  <.icon name="hero-sparkles" class="size-2.5" /> v{@updater_info.latest_version}
                </.link>
              <% end %>
            </div>

            <button
              type="button"
              id="theme-toggle-desktop"
              phx-hook="ThemeToggle"
              class="btn btn-ghost btn-xs text-base-content/60 hover:text-base-content cursor-pointer p-1"
              title="Toggle Dark/Light Mode"
              aria-label="Toggle Theme"
            >
              <.icon name="hero-sun" class="size-3.5 hidden [[data-theme=dark]_&]:block" />
              <.icon name="hero-moon" class="size-3.5 block [[data-theme=dark]_&]:hidden" />
            </button>
          </div>
        </div>
      </aside>

      <!-- Main Content Area -->
      <div class="flex-1 flex flex-col min-w-0 h-full overflow-hidden">
        <!-- Mobile Top Bar with Slide-out Drawer Menu -->
        <header class="h-16 flex items-center justify-between px-4 sm:px-6 border-b border-base-300 lg:hidden bg-base-100 shrink-0">
          <.link navigate={~p"/"} class="flex items-center gap-2 shrink-0">
            <img src={~p"/images/logo.png"} width="28" />
            <span class="font-bold text-sm uppercase tracking-wider text-base-content">Hermit</span>
          </.link>

          <div class="flex items-center gap-2">
            <%= if @updater_info.update_available? do %>
              <.link
                navigate={~p"/settings"}
                class="badge badge-warning badge-xs font-mono text-[10px] gap-1"
              >
                v{@updater_info.latest_version}
              </.link>
            <% end %>

            <button
              type="button"
              id="theme-toggle-mobile"
              phx-hook="ThemeToggle"
              class="btn btn-ghost btn-sm text-base-content/70 hover:text-base-content cursor-pointer px-2"
              title="Toggle Dark/Light Mode"
              aria-label="Toggle Theme"
            >
              <.icon name="hero-sun" class="size-4 hidden [[data-theme=dark]_&]:block" />
              <.icon name="hero-moon" class="size-4 block [[data-theme=dark]_&]:hidden" />
            </button>

            <button
              type="button"
              phx-click={
                JS.remove_class("hidden", to: "#mobile-nav-drawer")
                |> JS.add_class("flex", to: "#mobile-nav-drawer")
              }
              class="btn btn-ghost btn-sm text-base-content/80 hover:text-base-content cursor-pointer px-2"
              aria-label="Open Navigation Menu"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
          </div>
        </header>

        <!-- Mobile Slide-over Navigation Drawer -->
        <div
          id="mobile-nav-drawer"
          class="hidden fixed inset-0 z-50 lg:hidden"
          role="dialog"
          aria-modal="true"
        >
          <div
            class="fixed inset-0 bg-black/50 backdrop-blur-xs"
            phx-click={
              JS.add_class("hidden", to: "#mobile-nav-drawer")
              |> JS.remove_class("flex", to: "#mobile-nav-drawer")
            }
          />
          <div class="relative z-10 w-72 max-w-[85vw] bg-base-100 border-r border-base-300 h-full flex flex-col justify-between shadow-2xl">
            <div class="overflow-y-auto">
              <div class="h-16 flex items-center justify-between px-5 border-b border-base-300">
                <.link
                  navigate={~p"/"}
                  phx-click={
                    JS.add_class("hidden", to: "#mobile-nav-drawer")
                    |> JS.remove_class("flex", to: "#mobile-nav-drawer")
                  }
                  class="flex items-center gap-2"
                >
                  <img src={~p"/images/logo.png"} width="26" />
                  <span class="font-bold text-base tracking-wider uppercase text-base-content">
                    Hermit
                  </span>
                </.link>
                <button
                  type="button"
                  phx-click={
                    JS.add_class("hidden", to: "#mobile-nav-drawer")
                    |> JS.remove_class("flex", to: "#mobile-nav-drawer")
                  }
                  class="btn btn-ghost btn-xs text-base-content/60 hover:text-base-content p-1"
                  aria-label="Close Navigation Menu"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>

              <div phx-click={
                JS.add_class("hidden", to: "#mobile-nav-drawer")
                |> JS.remove_class("flex", to: "#mobile-nav-drawer")
              }>
                <.nav_menu active={@active} />
              </div>
            </div>

            <div class="p-4 border-t border-base-300 flex items-center justify-between text-[11px] font-mono text-base-content/50">
              <span>Hermit v{@updater_info.current_version}</span>
              <span class="text-emerald-500">Native</span>
            </div>
          </div>
        </div>

        <!-- Main Scrollable Content -->
        <main class="flex-1 overflow-y-auto px-4 py-6 sm:px-6 sm:py-8 lg:px-8 bg-base-200/10">
          <div class="mx-auto max-w-7xl">
            {@inner_content}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :active, :atom, required: true

  defp nav_menu(assigns) do
    ~H"""
    <nav class="p-4 space-y-5">
      <!-- Group 1: VPN & Tunnels -->
      <div class="space-y-1">
        <div class="text-[10px] font-bold text-base-content/40 tracking-wider px-3 pb-1 uppercase">
          VPN & Tunnels
        </div>
        <.sidebar_link navigate={~p"/"} active={@active == :dashboard} icon="hero-squares-2x2">
          Dashboard
        </.sidebar_link>
        <.sidebar_link
          navigate={~p"/inbounds"}
          active={@active == :inbounds}
          icon="hero-arrow-down-left"
        >
          Inbounds
        </.sidebar_link>
        <.sidebar_link
          navigate={~p"/outbounds"}
          active={@active == :outbounds}
          icon="hero-arrow-up-right"
        >
          Outbounds
        </.sidebar_link>
      </div>

      <!-- Group 2: Smart Routing -->
      <div class="space-y-1">
        <div class="text-[10px] font-bold text-base-content/40 tracking-wider px-3 pb-1 uppercase">
          Smart Routing
        </div>
        <.sidebar_link
          navigate={~p"/dns/services"}
          active={@active == :dns_services}
          icon="hero-sparkles"
        >
          Services
        </.sidebar_link>
        <.sidebar_link
          navigate={~p"/dns/rules"}
          active={@active == :dns_rules}
          icon="hero-list-bullet"
        >
          Custom Rules
        </.sidebar_link>
      </div>

      <!-- Group 3: DNS & Filtering -->
      <div class="space-y-1">
        <div class="text-[10px] font-bold text-base-content/40 tracking-wider px-3 pb-1 uppercase">
          DNS & Filtering
        </div>
        <.sidebar_link
          navigate={~p"/dns/endpoints"}
          active={@active == :dns_endpoints}
          icon="hero-adjustments-horizontal"
        >
          Endpoints
        </.sidebar_link>
        <.sidebar_link
          navigate={~p"/dns"}
          active={@active == :dns_profiles}
          icon="hero-globe-alt"
        >
          Profiles & Logs
        </.sidebar_link>
        <.sidebar_link
          navigate={~p"/dns/blocklists"}
          active={@active == :dns_blocklists}
          icon="hero-shield-check"
        >
          Blocklists
        </.sidebar_link>
      </div>

      <!-- Group 4: System -->
      <div class="space-y-1">
        <div class="text-[10px] font-bold text-base-content/40 tracking-wider px-3 pb-1 uppercase">
          System
        </div>
        <.sidebar_link
          navigate={~p"/settings"}
          active={@active == :settings}
          icon="hero-cog-6-tooth"
        >
          Settings
        </.sidebar_link>
      </div>
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 px-3 py-2.5 text-xs font-medium uppercase tracking-wider rounded-[6px] transition-colors cursor-pointer",
        @active && "bg-emerald-500/10 text-emerald-500 border border-emerald-500/20",
        !@active && "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp active_route(assigns) do
    case assigns[:socket] do
      nil ->
        :dashboard

      socket ->
        case socket.view do
          HermitWeb.DashboardLive -> :dashboard
          HermitWeb.TunnelDetailLive -> :dashboard
          HermitWeb.DnsEndpointLive -> :dns_endpoints
          HermitWeb.InboundLive -> :inbounds
          HermitWeb.InboundDetailLive -> :inbounds
          HermitWeb.OutboundLive -> :outbounds
          HermitWeb.DnsServicesLive -> :dns_services
          HermitWeb.DnsRulesLive -> :dns_rules
          HermitWeb.DnsProfileLive -> :dns_profiles
          HermitWeb.BlocklistLive -> :dns_blocklists
          HermitWeb.SystemLive -> :settings
          _ -> :dashboard
        end
    end
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} close_after={5000} />
      <.flash kind={:error} flash={@flash} close_after={5000} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
