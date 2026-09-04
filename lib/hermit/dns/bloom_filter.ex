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
    byte_size = div(bit_size, 8)
    num_words = div(byte_size + 7, 8)
    ref = :atomics.new(num_words, signed: false)

    # If binary has existing bytes, populate the atomics array
    if byte_size(binary) > 0 do
      pad_size = num_words * 8 - byte_size(binary)
      padded_binary = if pad_size > 0, do: binary <> <<0::size(pad_size * 8)>>, else: binary
      load_binary_to_atomics(padded_binary, ref, 1)
    end

    # Set bits directly into atomics array for all domains
    Enum.each(domains, fn domain ->
      domain_down = String.downcase(domain)

      Enum.each(@salts, fn salt ->
        bit_idx = :erlang.phash2({domain_down, salt}, bit_size)
        word_idx = div(bit_idx, 64) + 1
        mask = 1 <<< (63 - rem(bit_idx, 64))

        curr = :atomics.get(ref, word_idx)

        if Bitwise.band(curr, mask) == 0 do
          :atomics.put(ref, word_idx, Bitwise.bor(curr, mask))
        end
      end)
    end)

    # Construct final binary from 64-bit words
    result =
      for idx <- 1..num_words, into: <<>> do
        <<:atomics.get(ref, idx)::64>>
      end

    binary_part(result, 0, byte_size)
  end

  defp load_binary_to_atomics(<<>>, _ref, _idx), do: :ok

  defp load_binary_to_atomics(<<word::64, rest::binary>>, ref, idx) do
    :atomics.put(ref, idx, word)
    load_binary_to_atomics(rest, ref, idx + 1)
  end

  @doc """
  Check if a domain is a member of the Bloom Filter stored in ETS.
  """
  def member?(_domain, nil), do: true

  def member?(domain, binary) when is_binary(binary) do
    domain_down = String.downcase(domain)
    member_downcased?(domain_down, binary)
  end

  @doc """
  Check if an already-downcased domain is a member of the Bloom Filter.
  Short-circuits on the first 0-bit to avoid unnecessary hashing and allocations.
  """
  def member_downcased?(_domain, nil), do: true

  def member_downcased?(domain_down, binary) when is_binary(binary) do
    bit_size = byte_size(binary) * 8

    check_salt(domain_down, 1, bit_size, binary) and
      check_salt(domain_down, 2, bit_size, binary) and
      check_salt(domain_down, 3, bit_size, binary) and
      check_salt(domain_down, 4, bit_size, binary)
  end

  defp check_salt(domain_down, salt, bit_size, binary) do
    bit_idx = :erlang.phash2({domain_down, salt}, bit_size)
    byte_idx = div(bit_idx, 8)
    bit_offset = rem(bit_idx, 8)
    byte = :binary.at(binary, byte_idx)

    # Extract bit at position using bitwise AND
    Bitwise.band(byte, 1 <<< (7 - bit_offset)) != 0
  end
end
