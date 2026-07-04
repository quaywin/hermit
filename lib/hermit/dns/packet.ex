defmodule Hermit.Dns.Packet do
  @moduledoc """
  Lightweight DNS binary packet parser and builder.
  Supports parsing basic queries and building A/NXDOMAIN responses.
  """

  @type qtype :: :A | :AAAA | :MX | :TXT | :CNAME | :NS | :PTR | :SOA | {:unknown, integer()}

  def parse(
        <<id::binary-size(2), flags::binary-size(2), qd_count::16, _an_count::16, _ns_count::16,
          _ar_count::16, rest::binary>>
      ) do
    if qd_count > 0 do
      case parse_name(rest, <<>>) do
        {:ok, domain, <<qtype_val::16, qclass_val::16, question_end::binary>>} ->
          # Compute how long the question section was in total
          question_len = byte_size(rest) - byte_size(question_end)
          question_section = binary_part(rest, 0, question_len)

          {:ok,
           %{
             id: id,
             flags: flags,
             domain: domain,
             qtype: parse_qtype(qtype_val),
             qtype_val: qtype_val,
             qclass: qclass_val,
             question_section: question_section
           }}

        _ ->
          {:error, :invalid_question}
      end
    else
      {:error, :no_questions}
    end
  end

  def parse(_), do: {:error, :truncated}

  defp parse_name(<<0, rest::binary>>, acc) do
    {:ok, strip_trailing_dot(acc), rest}
  end

  defp parse_name(<<len, label::binary-size(len), rest::binary>>, acc) do
    parse_name(rest, <<acc::binary, label::binary, ".">>)
  end

  defp parse_name(_, _acc), do: :error

  defp strip_trailing_dot(<<>>), do: ""

  defp strip_trailing_dot(binary) do
    size = byte_size(binary) - 1
    binary_part(binary, 0, size)
  end

  defp parse_qtype(1), do: :A
  defp parse_qtype(28), do: :AAAA
  defp parse_qtype(15), do: :MX
  defp parse_qtype(16), do: :TXT
  defp parse_qtype(5), do: :CNAME
  defp parse_qtype(2), do: :NS
  defp parse_qtype(12), do: :PTR
  defp parse_qtype(6), do: :SOA
  defp parse_qtype(val), do: {:unknown, val}

  def qtype_to_string(:A), do: "A"
  def qtype_to_string(:AAAA), do: "AAAA"
  def qtype_to_string(:MX), do: "MX"
  def qtype_to_string(:TXT), do: "TXT"
  def qtype_to_string(:CNAME), do: "CNAME"
  def qtype_to_string(:NS), do: "NS"
  def qtype_to_string(:PTR), do: "PTR"
  def qtype_to_string(:SOA), do: "SOA"
  def qtype_to_string({:unknown, val}), do: "TYPE_#{val}"

  @doc """
  Builds a standard NXDOMAIN response.
  """
  def build_nxdomain(id, question_section) do
    # Flags: QR=1, Opcode=0, AA=1, TC=0, RD=1, RA=1, Z=0, RCODE=3 (NXDOMAIN)
    # Binary: <<1::1, 0::4, 1::1, 0::1, 1::1, 1::1, 0::3, 3::4>> -> 0x85, 0x83 (or 0x81, 0x83 depending on AA)
    # Standard query response with RD, RA, and Name Error (3): 0x81, 0x83
    header = <<id::binary, 0x81, 0x83, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
    header <> question_section
  end

  @doc """
  Builds an A record (IPv4) response for redirect.
  """
  def build_a_response(id, question_section, ip_str) do
    case parse_ip(ip_str) do
      {:ok, {a, b, c, d}} ->
        # Flags: QR=1, Opcode=0, AA=1, TC=0, RD=1, RA=1, Z=0, RCODE=0 (No Error) -> 0x81, 0x80
        # 1 Question, 1 Answer RR
        header = <<id::binary, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>>
        # Answer RR uses pointer compression pointing to offset 12 (0xc00c)
        answer =
          <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, a, b, c, d>>

        header <> question_section <> answer

      _ ->
        # Fallback to Server Failure (RCODE 2)
        header = <<id::binary, 0x81, 0x82, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
        header <> question_section
    end
  end

  # Helper to parse IPv4 string into 4-tuple
  defp parse_ip(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, {_, _, _, _} = tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  @doc """
  Extracts the minimum TTL from a DNS response packet.
  If the response is NXDOMAIN, returns 5.
  If the response is a successful resolution, parses answers and returns the minimum TTL,
  clamped between 5 and 3600 seconds.
  """
  def extract_min_ttl(
        <<_id::binary-size(2), flags::binary-size(2), qd_count::16, an_count::16, _ns_count::16,
          _ar_count::16, rest::binary>>
      ) do
    <<_qr::1, _opcode::4, _aa::1, _tc::1, _rd::1, _ra::1, _z::3, rcode::4>> = flags

    cond do
      rcode == 0 and an_count > 0 ->
        case skip_questions(rest, qd_count) do
          {:ok, answers_data} ->
            case parse_rrs(answers_data, an_count, []) do
              {:ok, ttls} ->
                if ttls == [] do
                  10
                else
                  min_ttl = Enum.min(ttls)
                  max(5, min(min_ttl, 3600))
                end

              _ ->
                10
            end

          _ ->
            10
        end

      rcode == 3 ->
        5

      true ->
        5
    end
  end

  def extract_min_ttl(_), do: 10

  defp skip_questions(rest, 0), do: {:ok, rest}

  defp skip_questions(rest, count) do
    case skip_name(rest) do
      {:ok, <<_qtype::16, _qclass::16, next::binary>>} ->
        skip_questions(next, count - 1)

      _ ->
        :error
    end
  end

  defp skip_name(<<0, rest::binary>>), do: {:ok, rest}

  defp skip_name(<<len, rest::binary>>) when len >= 192 do
    case rest do
      <<_offset, next::binary>> -> {:ok, next}
      _ -> :error
    end
  end

  defp skip_name(<<len, rest::binary>>) do
    if byte_size(rest) >= len do
      <<_label::binary-size(len), next::binary>> = rest
      skip_name(next)
    else
      :error
    end
  end

  defp skip_name(_), do: :error

  @doc """
  Parses all resolved A (IPv4) or AAAA (IPv6) addresses from a DNS response packet
  and returns them as a list of IP address strings.
  """
  def extract_resolved_ips(
        <<_id::binary-size(2), flags::binary-size(2), qd_count::16, an_count::16, _ns_count::16,
          _ar_count::16, rest::binary>>
      ) do
    <<_qr::1, _opcode::4, _aa::1, _tc::1, _rd::1, _ra::1, _z::3, rcode::4>> = flags

    if rcode == 0 and an_count > 0 do
      case skip_questions(rest, qd_count) do
        {:ok, answers_data} ->
          case parse_ips_from_rrs(answers_data, an_count, []) do
            {:ok, ips} -> ips
            _ -> []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  def extract_resolved_ips(_), do: []

  defp parse_ips_from_rrs(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_ips_from_rrs(rest, count, acc) do
    case skip_name(rest) do
      {:ok, <<type::16, _class::16, _ttl::32, rd_len::16, rd_data::binary-size(rd_len), next::binary>>} ->
        new_acc =
          case {type, rd_data} do
            {1, <<a, b, c, d>>} ->
              ["#{a}.#{b}.#{c}.#{d}" | acc]

            {28, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>} ->
              ip_str =
                [a, b, c, d, e, f, g, h]
                |> Enum.map(&Integer.to_string(&1, 16))
                |> Enum.join(":")
                |> String.downcase()

              [ip_str | acc]

            _ ->
              acc
          end

        parse_ips_from_rrs(next, count - 1, new_acc)

      _ ->
        if acc != [] do
          {:ok, Enum.reverse(acc)}
        else
          :error
        end
    end
  end

  defp parse_rrs(_rest, 0, acc), do: {:ok, acc}

  defp parse_rrs(rest, count, acc) do
    case skip_name(rest) do
      {:ok,
       <<_type::16, _class::16, ttl::32, rd_len::16, _rd_data::binary-size(rd_len), next::binary>>} ->
        parse_rrs(next, count - 1, [ttl | acc])

      _ ->
        if acc != [] do
          {:ok, acc}
        else
          :error
        end
    end
  end
end
