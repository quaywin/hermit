defmodule Hermit.Repo do
  use Ecto.Repo,
    otp_app: :hermit,
    adapter: Ecto.Adapters.SQLite3
end
