defmodule Hermit.Vpn.NamespaceTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Namespace

  test "create_endpoint_namespace calculates IP and subnet matching DNS worker octet calculation" do
    endpoint_id = 1
    octet = (max(endpoint_id, 1) - 1) |> rem(250)
    expected_ns_ip = "10.251.#{octet}.2"
    expected_subnet = "10.251.#{octet}.0/30"

    assert {:ok, result} = Namespace.create_endpoint_namespace(endpoint_id)
    assert result.ns_ip == expected_ns_ip
    assert result.subnet == expected_subnet

    # Endpoint 2 must allocate a distinct non-colliding subnet
    endpoint_id_2 = 2
    octet_2 = (max(endpoint_id_2, 1) - 1) |> rem(250)
    assert {:ok, result_2} = Namespace.create_endpoint_namespace(endpoint_id_2)
    assert result_2.ns_ip == "10.251.#{octet_2}.2"
    assert result_2.subnet == "10.251.#{octet_2}.0/30"
    assert result_2.ns_ip != result.ns_ip
  end
end
