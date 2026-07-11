import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hermit start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hermit, HermitWeb.Endpoint, server: true
end

config :hermit, HermitWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "3000"))]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(System.get_env("STORAGE_BASE_PATH", "/app/storage"), "hermit_prod.db")

  config :hermit, Hermit.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # We read it from the environment variable SECRET_KEY_BASE, or check the storage directory
  # for a persistent key file. If neither exists, we automatically generate a strong random
  # key and save it to the storage directory (Zero-Config Security).
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        storage_base = System.get_env("STORAGE_BASE_PATH") || "/app/storage"
        key_file_path = Path.join(storage_base, ".secret_key_base")

        case File.read(key_file_path) do
          {:ok, content} ->
            String.trim(content)

          _ ->
            # Generate a cryptographically strong 64-byte secret key encoded as Base64
            generated_key = :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)

            try do
              File.mkdir_p!(storage_base)
              File.write!(key_file_path, generated_key)
              generated_key
            rescue
              e ->
                IO.inspect(e,
                  label: "Warning: Failed to write persistent secret_key_base to storage"
                )

                generated_key
            end
        end
      )

  host = System.get_env("PHX_HOST") || "example.com"

  config :hermit, HermitWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: :conn,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    https: [
      port: String.to_integer(System.get_env("HTTPS_PORT", "3443")),
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hermit, HermitWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :hermit, HermitWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :hermit, Hermit.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end

if config_env() != :test do
  storage_default =
    if config_env() == :dev, do: Path.expand("storage", File.cwd!()), else: "/app/storage"

  config :hermit, :docker, tailscale_auth_key: System.get_env("TAILSCALE_AUTH_KEY")

  config :hermit, :storage, base_path: System.get_env("STORAGE_BASE_PATH", storage_default)
end
