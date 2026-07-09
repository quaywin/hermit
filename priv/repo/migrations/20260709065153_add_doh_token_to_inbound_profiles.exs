defmodule Hermit.Repo.Migrations.AddDohTokenToInboundProfiles do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:inbound_profiles) do
      add :doh_token, :string
    end

    flush()

    execute fn ->
      repo = repo()
      profiles = repo.all(from p in "inbound_profiles", select: p.id)
      for id <- profiles do
        token = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
        repo.update_all(from(p in "inbound_profiles", where: p.id == ^id), set: [doh_token: token])
      end
    end

    create unique_index(:inbound_profiles, [:doh_token])
  end

  def down do
    drop_if_exists unique_index(:inbound_profiles, [:doh_token])
    alter table(:inbound_profiles) do
      remove :doh_token
    end
  end
end
