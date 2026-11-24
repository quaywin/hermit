defmodule Hermit.Dns.ProvidersTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.Providers

  test "lists expected providers and presets" do
    ids = Providers.all() |> Enum.map(& &1.id)
    assert "controld" in ids
    assert "controld_community" in ids
    assert "adguard" in ids
    assert "cloudflare" in ids
    assert "quad9" in ids
    assert "custom" in ids

    assert length(Providers.presets_for("controld")) == 6
    assert length(Providers.presets_for("controld_community")) == 12
    assert Providers.presets_for("custom") == []
  end

  test "resolves UDP and DoH upstream endpoints for providers" do
    assert Providers.resolve_upstream("controld", "p2", :udp) == "76.76.2.2, 76.76.10.2"
    assert Providers.resolve_upstream("controld", "p2", :doh) == "https://freedns.controld.com/p2"
    assert Providers.resolve_upstream("controld", "family", :udp) == "76.76.2.4, 76.76.10.4"
    assert Providers.resolve_upstream("controld", "uncensored", :udp) == "76.76.2.5, 76.76.10.5"

    assert Providers.resolve_upstream("controld_community", "x-hagezi-pro", :udp) ==
             "https://freedns.controld.com/x-hagezi-pro"

    assert Providers.resolve_upstream("adguard", "family", :udp) == "94.140.14.15, 94.140.15.16"

    assert Providers.resolve_upstream("adguard", "family", :doh) ==
             "https://family.adguard-dns.com/dns-query"

    assert Providers.resolve_upstream("adguard", "unfiltered", :doh) ==
             "https://unfiltered.adguard-dns.com/dns-query"

    assert Providers.resolve_upstream("cloudflare", "malware", :doh) ==
             "https://security.cloudflare-dns.com/dns-query"

    assert Providers.resolve_upstream("quad9", "ecs", :udp) == "9.9.9.11, 149.112.112.11"
  end

  test "detects provider, preset, and protocol with whitespace normalization" do
    assert Providers.detect("76.76.2.2, 76.76.10.2") == {"controld", "p2", :udp}
    assert Providers.detect("76.76.2.2   76.76.10.2") == {"controld", "p2", :udp}
    assert Providers.detect("https://freedns.controld.com/family") == {"controld", "family", :doh}

    assert Providers.detect("https://freedns.controld.com/x-oisd") ==
             {"controld_community", "x-oisd", :doh}

    assert Providers.detect("94.140.14.14,94.140.15.15") == {"adguard", "default", :udp}
    assert Providers.detect("1.1.1.1, 1.0.0.1") == {"cloudflare", "standard", :udp}
  end

  test "detects custom DoH and arbitrary IP upstreams as custom" do
    assert Providers.detect("https://dns.nextdns.io/abc123") == {"custom", nil, :doh}
    assert Providers.detect("https://dns.controld.com/mycustomid") == {"custom", nil, :doh}
    assert Providers.detect("1.1.1.1, 8.8.8.8") == {"custom", nil, :udp}
    assert Providers.detect(nil) == {"custom", nil, :doh}
  end
end
