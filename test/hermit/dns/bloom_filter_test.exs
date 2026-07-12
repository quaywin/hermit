defmodule Hermit.Dns.BloomFilterTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.BloomFilter

  test "calculates optimal bit size and aligns to byte boundaries" do
    # Minimum size logic
    assert BloomFilter.calculate_size(5) == 1000
    assert BloomFilter.calculate_size(50) == 1000

    # 10 bits per item logic (150 * 10 = 1500 -> aligned to 8-bit boundary -> 1504)
    assert BloomFilter.calculate_size(150) == 1504
    assert rem(BloomFilter.calculate_size(150), 8) == 0
  end

  test "initializes empty bloom filter with all zero bits" do
    size = 1000
    bloom = BloomFilter.new(size)

    assert byte_size(bloom) == div(size, 8)
    assert bloom == <<0::size(size)>>
  end

  test "inserts and checks member correctly" do
    domains = ["google.com", "facebook.com", "ads.yahoo.com", "sub.domain.co.uk"]
    size = BloomFilter.calculate_size(length(domains))
    empty_bloom = BloomFilter.new(size)

    bloom = BloomFilter.put_many(empty_bloom, domains, size)

    # All inserted elements must definitely be members
    for domain <- domains do
      assert BloomFilter.member?(domain, bloom), "Expected #{domain} to be in the Bloom Filter"
    end

    # Random non-inserted elements should not be members (with high probability)
    clean_domains = ["github.com", "elixir-lang.org", "wikipedia.org", "kernel.org"]

    for clean <- clean_domains do
      refute BloomFilter.member?(clean, bloom), "Expected #{clean} NOT to be in the Bloom Filter"
    end
  end

  test "member check is case-insensitive" do
    domains = ["GoOgLe.CoM", "AdS.yAhOo.NeT"]
    size = BloomFilter.calculate_size(length(domains))
    empty_bloom = BloomFilter.new(size)

    bloom = BloomFilter.put_many(empty_bloom, domains, size)

    assert BloomFilter.member?("google.com", bloom)
    assert BloomFilter.member?("GOOGLE.COM", bloom)
    assert BloomFilter.member?("ads.yahoo.net", bloom)
    assert BloomFilter.member?("ADS.YAHOO.NET", bloom)
  end

  test "calculates false positive rate within safe boundaries" do
    # With 1000 domains inserted into 10000 bits, check false positive rate on 1000 clean domains
    inserted = Enum.map(1..1000, &"blocked-domain-#{&1}.com")
    clean = Enum.map(1..1000, &"clean-domain-#{&1}.com")

    size = BloomFilter.calculate_size(length(inserted))
    empty_bloom = BloomFilter.new(size)
    bloom = BloomFilter.put_many(empty_bloom, inserted, size)

    # 1. Verify all inserted are members
    Enum.each(inserted, fn domain ->
      assert BloomFilter.member?(domain, bloom)
    end)

    # 2. Count false positives
    false_positives =
      clean
      |> Enum.count(fn domain -> BloomFilter.member?(domain, bloom) end)

    # 1% target with K=4, size=10 bits per item. With 1000 test cases, it should be around 10 false positives.
    # We assert it is strictly less than 3% (30 false positives) to account for statistical variance.
    assert false_positives < 30, "Too many false positives: #{false_positives}/1000"
  end
end
