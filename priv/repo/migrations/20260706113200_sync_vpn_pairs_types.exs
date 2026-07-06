defmodule Hermit.Repo.Migrations.SyncVpnPairsTypes do
  use Ecto.Migration

  def up do
    execute """
    UPDATE vpn_pairs
    SET inbound_type = (
      SELECT type FROM inbound_profiles WHERE inbound_profiles.id = vpn_pairs.inbound_profile_id
    )
    WHERE inbound_profile_id IS NOT NULL;
    """

    execute """
    UPDATE vpn_pairs
    SET outbound_type = (
      SELECT type FROM outbound_profiles WHERE outbound_profiles.id = vpn_pairs.outbound_profile_id
    )
    WHERE outbound_profile_id IS NOT NULL;
    """
  end

  def down do
    :ok
  end
end
