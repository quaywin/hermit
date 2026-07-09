defmodule HermitWeb.Router do
  use HermitWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HermitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :basic_auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HermitWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/inbounds", InboundLive
    live "/outbounds", OutboundLive
    live "/tunnels/:id", TunnelDetailLive
    live "/inbounds/:id", InboundDetailLive
    live "/dns", DnsProfileLive
    live "/dns/blocklists", BlocklistLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", HermitWeb do
  #   pipe_through :api
  # end

  scope "/dns-query/:doh_token", HermitWeb do
    get "/", DNSController, :query, log: false
    post "/", DNSController, :query, log: false
    get "/mobileconfig", DNSController, :mobileconfig
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hermit, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
  end

  defp basic_auth(conn, _opts) do
    username = System.get_env("HERMIT_BASIC_AUTH_USER")
    password = System.get_env("HERMIT_BASIC_AUTH_PASS")

    if username && password do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    else
      conn
    end
  end
end
