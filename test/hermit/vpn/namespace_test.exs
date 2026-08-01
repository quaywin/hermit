defmodule Hermit.Vpn.NamespaceTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Namespace

  test "create_endpoint_namespace calculates IP and subnet matching DNS worker octet calculation" do
    endpoint_id = 1
    octet = div(endpoint_id, 250) |> rem(250)
    expected_ns_ip = "10.251.#{octet}.2"
    expected_subnet = "10.251.#{octet}.0/30"

    assert {:ok, result} = Namespace.create_endpoint_namespace(endpoint_id)
    assert result.ns_ip == expected_ns_ip
    assert result.subnet == expected_subnet
  end
end
