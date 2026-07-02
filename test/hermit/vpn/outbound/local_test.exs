defmodule Hermit.Vpn.Outbound.LocalTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Outbound.Local, as: LocalOutbound
  alias Hermit.Vpn.OutboundProfile

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "mock bootstrap, cleanup, and status" do
    pair_id = "test_local_pair"
    storage_dir = Path.expand("storage/test_local_pair", File.cwd!())
    File.mkdir_p!(storage_dir)

    on_exit(fn ->
      File.rm_rf!(storage_dir)
    end)

    # Bootstrap should return {:ok, "eth0"} in mock mode
    assert {:ok, "eth0"} = LocalOutbound.bootstrap(pair_id, storage_dir, %{})

    # Status should be :running when storage dir exists
    assert :running = LocalOutbound.get_status(pair_id, storage_dir)

    # Metrics should return mock metrics
    assert {:ok, %{bytes_received: 1024, bytes_sent: 2048}} =
             LocalOutbound.get_metrics(pair_id, storage_dir)

    # Cleanup should return :ok
    assert :ok = LocalOutbound.cleanup(pair_id, storage_dir)
  end

  test "validate outbound profile changeset for local type" do
    # Valid: empty config (uses defaults)
    changeset =
      OutboundProfile.changeset(%OutboundProfile{}, %{
        name: "Local Outbound Default",
        type: "local",
        config: %{}
      })

    assert changeset.valid?

    # Valid: explicit CIDR ips
    changeset =
      OutboundProfile.changeset(%OutboundProfile{}, %{
        name: "Local Outbound Custom",
        type: "local",
        config: %{
          "local_ip" => "192.168.10.2/30",
          "host_ip" => "192.168.10.1/30"
        }
      })

    assert changeset.valid?

    # Invalid: invalid local_ip format (not CIDR)
    changeset =
      OutboundProfile.changeset(%OutboundProfile{}, %{
        name: "Local Outbound Invalid",
        type: "local",
        config: %{
          "local_ip" => "192.168.10.2",
          "host_ip" => "192.168.10.1/30"
        }
      })

    refute changeset.valid?
    {error_msg, _} = Keyword.get(changeset.errors, :config)
    assert error_msg =~ "must be in CIDR format"

    # Invalid: invalid host_ip format (not CIDR)
    changeset =
      OutboundProfile.changeset(%OutboundProfile{}, %{
        name: "Local Outbound Invalid",
        type: "local",
        config: %{
          "local_ip" => "192.168.10.2/30",
          "host_ip" => "192.168.10.1"
        }
      })

    refute changeset.valid?
    {error_msg, _} = Keyword.get(changeset.errors, :config)
    assert error_msg =~ "must be in CIDR format"
  end
end
