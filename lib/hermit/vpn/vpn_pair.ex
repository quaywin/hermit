defmodule Hermit.Vpn.VpnPair do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:pair_id, :string, autogenerate: false}
  schema "vpn_pairs" do
    belongs_to(:inbound_profile, Hermit.Vpn.InboundProfile)
    belongs_to(:outbound_profile, Hermit.Vpn.OutboundProfile)

    field(:wg_config, :string, virtual: true)

    field(:inbound_type, :string, default: "tailscale")
    field(:inbound_config, :map, default: %{})
    field(:outbound_type, :string, default: "wireguard")
    field(:outbound_config, :map, default: %{})

    field(:status, :string, default: "running")
    field(:wg_status, :string, default: "stopped")
    field(:ts_status, :string, default: "stopped")
    field(:wg_error_reason, :string)
    field(:ts_error_reason, :string)
    field(:started_at, :integer)

    timestamps()
  end

  def changeset(vpn_pair, attrs) do
    vpn_pair
    |> cast(attrs, [
      :pair_id,
      :inbound_profile_id,
      :outbound_profile_id,
      :inbound_type,
      :inbound_config,
      :outbound_type,
      :outbound_config,
      :wg_config,
      :status,
      :wg_status,
      :ts_status,
      :wg_error_reason,
      :ts_error_reason,
      :started_at
    ])
    |> validate_required([:pair_id, :inbound_profile_id, :outbound_profile_id])
    |> validate_format(:pair_id, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> validate_wg_config_if_present()
  end

  defp validate_wg_config_if_present(changeset) do
    if Map.has_key?(changeset.params || %{}, "wg_config") do
      val = get_field(changeset, :wg_config)

      if is_nil(val) or String.trim(val) == "" do
        add_error(changeset, :wg_config, "can't be blank")
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc """
  Checks if the given outbound profile is already in use by another active tunnel.
  Returns `{:error, conflicting_pair_id}` if a conflict is found, otherwise `:ok`.
  """
  def check_outbound_conflict(outbound_profile_id, current_pair_id) do
    if is_nil(outbound_profile_id) do
      :ok
    else
      import Ecto.Query

      query =
        from(p in Hermit.Vpn.VpnPair,
          where: p.outbound_profile_id == ^outbound_profile_id,
          where: p.pair_id != ^current_pair_id,
          where: p.wg_status in ["running", "starting"]
        )

      case Hermit.Repo.all(query) do
        [conflicting_pair | _] ->
          {:error, conflicting_pair.pair_id}

        [] ->
          :ok
      end
    end
  end
end
