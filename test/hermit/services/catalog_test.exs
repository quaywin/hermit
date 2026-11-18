defmodule Hermit.Services.CatalogTest do
  use ExUnit.Case, async: true
  alias Hermit.Services.Catalog

  test "returns all services and valid metadata" do
    services = Catalog.all()
    assert is_list(services)
    assert length(services) > 10

    for svc <- services do
      assert is_binary(svc.id) and svc.id != ""
      assert is_binary(svc.name) and svc.name != ""
      assert is_atom(svc.category)
      assert is_list(svc.domains) and svc.domains != []
      assert Enum.all?(svc.domains, &(is_binary(&1) and &1 != ""))
    end
  end

  test "get/1 finds service by id" do
    openai = Catalog.get("openai")
    assert openai != nil
    assert openai.name == "OpenAI / ChatGPT"
    assert "*.chatgpt.com" in openai.domains

    assert Catalog.get("nonexistent") == nil
  end

  test "by_category/1 filters services by category" do
    streaming = Catalog.by_category(:streaming)
    assert length(streaming) > 0
    assert Enum.all?(streaming, &(&1.category == :streaming))

    ai = Catalog.by_category("ai")
    assert length(ai) > 0
    assert Enum.all?(ai, &(&1.category == :ai))
  end

  test "search/1 matches by name, id, or domain" do
    results = Catalog.search("netflix")
    assert length(results) == 1
    assert hd(results).id == "netflix"

    results_domain = Catalog.search("oaistatic.com")
    assert length(results_domain) == 1
    assert hd(results_domain).id == "openai"
  end

  test "domains_for_service/1 returns expected domains" do
    domains = Catalog.domains_for_service("claude")
    assert "*.claude.ai" in domains
    assert Catalog.domains_for_service("unknown") == []
  end
end
