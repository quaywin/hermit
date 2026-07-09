defmodule Hermit.Dns.Blocklist do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_blocklists" do
    field :name, :string
    field :url, :string
    field :enabled, :boolean, default: true
    field :description, :string
    field :format, :string, default: "adguard"
    field :rules_count, :integer, default: 0
    field :last_fetched_at, :naive_datetime

    many_to_many :dns_configs, Hermit.Vpn.DnsConfig, join_through: "dns_configs_blocklists", join_keys: [dns_blocklist_id: :id, dns_config_id: :id]

    timestamps()
  end

  def changeset(blocklist, attrs) do
    blocklist
    |> cast(attrs, [:name, :url, :enabled, :description, :format, :rules_count, :last_fetched_at])
    |> validate_required([:name, :url, :format])
    |> validate_inclusion(:format, ["adguard", "hosts", "domains"])
  end
end
