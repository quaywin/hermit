defmodule HermitWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HermitWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current scope"

  def app(assigns) do
    assigns = assign(assigns, :active, active_route(assigns))

    ~H"""
    <div class="flex h-screen w-screen overflow-hidden bg-base-100 text-base-content font-sans antialiased">
      <!-- Sidebar cho Desktop (luôn hiển thị trên màn hình lớn lg) -->
      <aside class="hidden lg:flex w-64 bg-base-100 border-r border-base-300 flex-col justify-between shrink-0 h-full">
        <div class="flex flex-col">
          <!-- Logo / Header -->
          <div class="h-16 flex items-center px-6 border-b border-base-300">
            <.link navigate={~p"/"} class="flex items-center gap-2">
              <img src={~p"/images/logo.png"} width="30" />
              <span class="font-bold text-lg tracking-wider uppercase text-base-content">Hermit</span>
            </.link>
          </div>

          <!-- Navigation Links -->
          <nav class="p-4 space-y-1">
            <.sidebar_link navigate={~p"/"} active={@active == :tunnels} icon="hero-server-stack">
              Tunnels
            </.sidebar_link>
            <.sidebar_link
              navigate={~p"/inbounds"}
              active={@active == :inbounds}
              icon="hero-arrow-down-left"
            >
              Inbound Profiles
            </.sidebar_link>
            <.sidebar_link
              navigate={~p"/outbounds"}
              active={@active == :outbounds}
              icon="hero-arrow-up-right"
            >
              Outbound Profiles
            </.sidebar_link>
            <.sidebar_link
              navigate={~p"/dns"}
              active={@active == :dns_profiles}
              icon="hero-globe-alt"
            >
              DNS Profiles
            </.sidebar_link>
            <.sidebar_link
              navigate={~p"/dns/blocklists"}
              active={@active == :dns_blocklists}
              icon="hero-shield-check"
            >
              Filters
            </.sidebar_link>
          </nav>
        </div>

        <!-- Sidebar Bottom (Info) -->
        <div class="p-4 border-t border-base-300 space-y-4 bg-base-100">
          <div class="text-[10px] text-base-content/40 text-center font-mono">
            v0.1.0-alpha
          </div>
        </div>
      </aside>

      <!-- Main Content Area -->
      <div class="flex-1 flex flex-col min-w-0 h-full overflow-hidden">
        <!-- Top Nav cho Mobile / Tablet (Ẩn trên màn hình lớn lg) -->
        <header class="h-16 flex items-center justify-between px-6 border-b border-base-300 lg:hidden bg-base-100 shrink-0">
          <div class="flex items-center gap-4">
            <.link navigate={~p"/"} class="flex items-center gap-2">
              <img src={~p"/images/logo.png"} width="28" />
              <span class="font-bold text-sm uppercase tracking-wider">Hermit</span>
            </.link>
            <!-- Mobile Menu Links -->
            <nav class="flex gap-3 text-[11px] font-semibold uppercase tracking-wider">
              <.link navigate={~p"/"} class={if @active == :tunnels, do: "text-emerald-500", else: "text-base-content/60"}>Tunnels</.link>
              <.link navigate={~p"/inbounds"} class={if @active == :inbounds, do: "text-emerald-500", else: "text-base-content/60"}>Inbounds</.link>
              <.link navigate={~p"/outbounds"} class={if @active == :outbounds, do: "text-emerald-500", else: "text-base-content/60"}>Outbounds</.link>
              <.link navigate={~p"/dns"} class={if @active == :dns_profiles, do: "text-emerald-500", else: "text-base-content/60"}>DNS</.link>
              <.link navigate={~p"/dns/blocklists"} class={if @active == :dns_blocklists, do: "text-emerald-500", else: "text-base-content/60"}>Filters</.link>
            </nav>
          </div>
          <.theme_toggle />
        </header>

        <!-- Container cuộn chứa nội dung chính -->
        <main class="flex-1 overflow-y-auto px-4 py-8 sm:px-6 lg:px-8 bg-base-200/10">
          <div class="mx-auto max-w-7xl">
            {@inner_content}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
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
      nil -> :tunnels
      socket ->
        case socket.view do
          HermitWeb.DashboardLive -> :tunnels
          HermitWeb.TunnelDetailLive -> :tunnels
          HermitWeb.InboundLive -> :inbounds
          HermitWeb.InboundDetailLive -> :inbounds
          HermitWeb.OutboundLive -> :outbounds
          HermitWeb.DnsProfileLive -> :dns_profiles
          HermitWeb.BlocklistLive -> :dns_blocklists
          _ -> :tunnels
        end
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
