defmodule Hermit.Vpn.DnsConfigTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.DnsConfig

  test "validates services map and custom rules with route_tunnel" do
    valid_attrs = %{
      name: "Streaming Profile",
      upstream_dns: "1.1.1.1, 8.8.8.8",
      services: %{
        "netflix" => %{"action" => "route_tunnel", "pair_id" => "wg_us"},
        "openai" => %{"action" => "route_tunnel", "pair_id" => "wg_sg"},
        "tiktok" => %{"action" => "block"}
      },
      custom_rules: [
        %{"domain" => "*.mycorp.internal", "action" => "route_tunnel", "value" => "wg_us"},
        %{"domain" => "tracker.com", "action" => "block", "value" => nil}
      ]
    }

    changeset = DnsConfig.changeset(%DnsConfig{}, valid_attrs)
    assert changeset.valid?

    invalid_attrs = %{
      name: "Bad Profile",
      upstream_dns: "1.1.1.1",
      services: %{
        "netflix" => %{"action" => "invalid_action"}
      },
      custom_rules: []
    }

    invalid_changeset = DnsConfig.changeset(%DnsConfig{}, invalid_attrs)
    refute invalid_changeset.valid?
    assert "contains invalid service configurations" in errors_on(invalid_changeset).services
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
