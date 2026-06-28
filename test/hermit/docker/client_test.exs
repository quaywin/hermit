defmodule Hermit.Docker.ClientTest do
  use ExUnit.Case, async: false
  alias Hermit.Docker.Client, as: DockerClient

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "get_container_status/1 returns not_found for non-existent container" do
    assert {:error, :not_found} = DockerClient.get_container_status("non_existent_container_123")
  end

  test "get_network_info/1 returns not_found for non-existent container" do
    assert {:error, :not_found} = DockerClient.get_network_info("non_existent_container_123")
  end

  test "returns daemon_unresponsive when mock_error is daemon_unresponsive" do
    original_config = Application.get_env(:hermit, :docker)

    Application.put_env(
      :hermit,
      :docker,
      Keyword.put(original_config, :mock_error, :daemon_unresponsive)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
    end)

    assert {:error, :daemon_unresponsive} = DockerClient.get_container_status("any_container")
  end

  test "strip_config/1 removes Address, DNS, MTU and ListenPort case-insensitively" do
    config = """
    [Interface]
    PrivateKey = wgpkey
    Address = 10.0.0.1/24
    dns = 1.1.1.1
    Mtu = 1420
    ListenPort = 51820
    listenport = 1234

    [Peer]
    PublicKey = peerpubkey
    Endpoint = 1.2.3.4:51820
    """

    stripped = DockerClient.strip_config(config)

    assert stripped =~ "PrivateKey = wgpkey"
    assert stripped =~ "PublicKey = peerpubkey"
    assert stripped =~ "Endpoint = 1.2.3.4:51820"
    refute stripped =~ "Address"
    refute stripped =~ "dns"
    refute stripped =~ "Mtu"
    refute stripped =~ "ListenPort"
    refute stripped =~ "listenport"
  end
end
