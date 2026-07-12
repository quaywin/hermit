defmodule Hermit.Dns.BloomFilter do
  @moduledoc """
  A pure Elixir, zero-dependency Bloom Filter implementation stored compactly as a single binary in ETS.
  Optimized for high-performance DNS filtering.
  """
  import Bitwise

  # K = 4 hash functions (salts)
  @salts [1, 2, 3, 4]
  # Target 10 bits per item (yields ~1% false positive rate with K=4)
  @bits_per_item 10

  @doc """
  Compute the optimal size of the Bloom Filter in bits based on the number of items.
  Aligned to 8-bit byte boundaries.
  """
  def calculate_size(item_count) do
    # Minimum size of 1000 bits
    raw_size = max(item_count * @bits_per_item, 1000)
    # Align to byte boundaries (multiple of 8)
    div(raw_size + 7, 8) * 8
  end

  @doc """
  Create an empty Bloom Filter binary of a specified bit size.
  """
  def new(bit_size) do
    <<0::size(bit_size)>>
  end

  @doc """
  Add a list of domains to a Bloom Filter and return the mutated binary.
  """
  def put_many(binary, domains, bit_size) do
    # To avoid mutating binary in a slow loop (copy-on-write),
    # we compute all set bit indices, map them to byte-index and bitmasks,
    # and then construct the final binary in one pass.
    byte_indices_with_masks =
      domains
      |> Enum.flat_map(fn domain ->
        compute_indices(domain, bit_size)
      end)
      |> Enum.reduce(%{}, fn bit_idx, acc ->
        byte_idx = div(bit_idx, 8)
        bit_offset = rem(bit_idx, 8)
        mask = 1 <<< (7 - bit_offset)

        Map.update(acc, byte_idx, mask, fn existing_mask ->
          Bitwise.bor(existing_mask, mask)
        end)
      end)

    # Build the binary by merging the masks with the original zero-filled binary
    byte_size = div(bit_size, 8)

    for i <- 0..(byte_size - 1), into: <<>> do
      original_byte = :binary.at(binary, i)
      mask = Map.get(byte_indices_with_masks, i, 0)
      <<Bitwise.bor(original_byte, mask)>>
    end
  end

  @doc """
  Check if a domain is a member of the Bloom Filter stored in ETS.
  """
  def member?(_domain, nil), do: true

  def member?(domain, binary) when is_binary(binary) do
    bit_size = byte_size(binary) * 8
    indices = compute_indices(domain, bit_size)

    Enum.all?(indices, fn bit_idx ->
      byte_idx = div(bit_idx, 8)
      bit_offset = rem(bit_idx, 8)
      byte = :binary.at(binary, byte_idx)

      # Extract bit at position using bitwise AND
      Bitwise.band(byte, 1 <<< (7 - bit_offset)) != 0
    end)
  end

  # Helper to compute K hash indices for a domain
  defp compute_indices(domain, bit_size) do
    domain_down = String.downcase(domain)

    Enum.map(@salts, fn salt ->
      # phash2 returns a hash in range [0, bit_size - 1]
      :erlang.phash2({domain_down, salt}, bit_size)
    end)
  end
end
