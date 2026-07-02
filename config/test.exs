import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hermit, boot_persisted_pairs: false

config :hermit, HermitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PU8mmuRdeJetQ5nyFZs+QdSuVySM5v6pIcQp04kLaKq6yoi/y/GkGDlod4QFpNxi",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Configure Tailscale integration for test
config :hermit, :docker,
  mock: true,
  tailscale_auth_key: "tskey-auth-default-test"

# Configure Storage base directory for test
config :hermit, :storage, base_path: Path.expand("storage", File.cwd!())

# Configure database for test
config :hermit, Hermit.Repo,
  database: Path.expand("storage/hermit_test.db", File.cwd!()),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5
