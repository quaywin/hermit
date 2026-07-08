defmodule Hermit.Dns.Packet do
  @moduledoc """
  DNS binary packet parser and builder using `dns_erlang`.
  Provides structured parse and build functions.
  """

  require Record

  Record.defrecord(
    :dns_message,
    Record.extract(:dns_message, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(:dns_query, Record.extract(:dns_query, from_lib: "dns_erlang/include/dns.hrl"))
  Record.defrecord(:dns_rr, Record.extract(:dns_rr, from_lib: "dns_erlang/include/dns.hrl"))

  Record.defrecord(
    :dns_rrdata_a,
    Record.extract(:dns_rrdata_a, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(
    :dns_rrdata_aaaa,
    Record.extract(:dns_rrdata_aaaa, from_lib: "dns_erlang/include/dns.hrl")
  )

  @type qtype :: :A | :AAAA | :MX | :TXT | :CNAME | :NS | :PTR | :SOA | {:unknown, integer()}

  def parse(packet) do
    case packet do
      # QR = 0 (Query)
      <<_id::16, 0::1, _rest::bits>> ->
        parse_query_fast(packet)

      # QR = 1 (Response) hoặc gói tin khác
      _ ->
        parse_response_slow(packet)
    end
  end

  defp parse_query_fast(<<id::16, _rest_header::binary-size(10), question_section::binary>> = packet) do
    case parse_name(question_section) do
      {domain, <<qtype_val::16, qclass::16, _rest::binary>>} ->
        id_bin = <<id::16>>
        flags_bin = if byte_size(packet) >= 4, do: binary_part(packet, 2, 2), else: <<0, 0>>
        query_rec = dns_query(name: domain, class: qclass, type: qtype_val)

        {:ok,
         %{
           id: id_bin,
           flags: flags_bin,
           domain: domain,
           qtype: to_qtype(qtype_val),
           qtype_val: qtype_val,
           qclass: qclass,
           query_record: query_rec
         }}

      _ ->
        parse_response_slow(packet)
    end
  end

  defp parse_query_fast(packet) do
    parse_response_slow(packet)
  end

  defp parse_name(data), do: parse_name(data, [])

  defp parse_name(<<0, rest::binary>>, labels) do
    domain = labels |> Enum.reverse() |> Enum.join(".")
    {domain, rest}
  end

  defp parse_name(<<len::8, label::binary-size(len), rest::binary>>, labels) do
    parse_name(rest, [label | labels])
  end

  defp parse_name(_, _), do: :error

  defp parse_response_slow(packet) do
    case :dns.decode_message(packet) do
      msg when Record.is_record(msg, :dns_message) ->
        qc = dns_message(msg, :qc)
        questions = dns_message(msg, :questions)

        case questions do
          [first_query | _] when qc > 0 ->
            domain = dns_query(first_query, :name)
            qclass = dns_query(first_query, :class)
            qtype_val = dns_query(first_query, :type)
            id = dns_message(msg, :id)

            id_bin = <<id::16>>
            flags_bin = if byte_size(packet) >= 4, do: binary_part(packet, 2, 2), else: <<0, 0>>

            {:ok,
             %{
               id: id_bin,
               flags: flags_bin,
               domain: domain,
               qtype: to_qtype(qtype_val),
               qtype_val: qtype_val,
               qclass: qclass,
               query_record: first_query
             }}

          _ ->
            {:error, :no_questions}
        end

      _ ->
        {:error, :invalid_packet}
    end
  end

  defp to_qtype(1), do: :A
  defp to_qtype(28), do: :AAAA
  defp to_qtype(15), do: :MX
  defp to_qtype(16), do: :TXT
  defp to_qtype(5), do: :CNAME
  defp to_qtype(2), do: :NS
  defp to_qtype(12), do: :PTR
  defp to_qtype(6), do: :SOA
  defp to_qtype(val), do: {:unknown, val}

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
  Builds a raw DNS query packet from a transaction ID and a query record.
  """
  def build_query_packet(tx_id, query_record) when Record.is_record(query_record, :dns_query) do
    msg =
      dns_message(
        id: tx_id,
        qr: false,
        rd: true,
        qc: 1,
        questions: [query_record]
      )

    :dns.encode_message(msg)
  end

  @doc """
  Builds a standard NXDOMAIN response.
  """
  def build_nxdomain(id_bin, query_record) when Record.is_record(query_record, :dns_query) do
    id_val = parse_id_bin(id_bin)

    msg =
      dns_message(
        id: id_val,
        qr: true,
        aa: false,
        rd: true,
        ra: true,
        # NXDOMAIN
        rc: 3,
        qc: 1,
        questions: [query_record]
      )

    :dns.encode_message(msg)
  end

  @doc """
  Builds a A/AAAA record response for redirect.
  """
  def build_a_response(id_bin, query_record, ip_str)
      when Record.is_record(query_record, :dns_query) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip_tuple} ->
        id_val = parse_id_bin(id_bin)
        domain = dns_query(query_record, :name)

        {type, rrdata} =
          case ip_tuple do
            {_, _, _, _} -> {1, dns_rrdata_a(ip: ip_tuple)}
            {_, _, _, _, _, _, _, _} -> {28, dns_rrdata_aaaa(ip: ip_tuple)}
          end

        answers = [dns_rr(name: domain, type: type, class: 1, ttl: 60, data: rrdata)]

        msg =
          dns_message(
            id: id_val,
            qr: true,
            aa: false,
            rd: true,
            ra: true,
            # NOERROR
            rc: 0,
            qc: 1,
            anc: 1,
            questions: [query_record],
            answers: answers
          )

        :dns.encode_message(msg)

      _ ->
        # Fallback to NXDOMAIN if IP is invalid
        build_nxdomain(id_bin, query_record)
    end
  end

  @doc """
  Safely updates the response code (RCODE) of a raw DNS packet.
  """
  def patch_rcode(packet, rcode) do
    case :dns.decode_message(packet) do
      msg when Record.is_record(msg, :dns_message) ->
        patched_msg = dns_message(msg, rc: rcode)
        :dns.encode_message(patched_msg)

      _ ->
        # Fallback to simple bitwise manipulation if decoding fails
        <<id::binary-size(2), _flags::binary-size(2), rest::binary>> = packet
        flags2 = 0x80 + rcode
        <<id::binary, 0x81, flags2, rest::binary>>
    end
  end

  defp parse_id_bin(<<val::16>>), do: val
  defp parse_id_bin(_), do: 0

  @doc """
  Parses metadata (minimum TTL and resolved IPs) from a DNS response packet in one pass.
  """
  def parse_response_metadata(packet, extract_ips? \\ true) do
    case :dns.decode_message(packet) do
      msg when Record.is_record(msg, :dns_message) ->
        rcode = dns_message(msg, :rc)
        answers = dns_message(msg, :answers)

        ttl =
          cond do
            rcode == 3 ->
              5

            rcode == 0 and length(answers) > 0 ->
              ttls =
                Enum.flat_map(answers, fn rr ->
                  if Record.is_record(rr, :dns_rr) do
                    [dns_rr(rr, :ttl)]
                  else
                    []
                  end
                end)

              if ttls == [] do
                10
              else
                min_ttl = Enum.min(ttls)
                max(5, min(min_ttl, 3600))
              end

            true ->
              5
          end

        ips =
          if rcode == 0 and extract_ips? do
            Enum.flat_map(answers, fn rr ->
              if Record.is_record(rr, :dns_rr) do
                type = dns_rr(rr, :type)
                data = dns_rr(rr, :data)

                case {type, data} do
                  {1, rrdata} when Record.is_record(rrdata, :dns_rrdata_a) ->
                    ip = dns_rrdata_a(rrdata, :ip)
                    [ip_to_string(ip)]

                  {28, rrdata} when Record.is_record(rrdata, :dns_rrdata_aaaa) ->
                    ip = dns_rrdata_aaaa(rrdata, :ip)
                    [ip_to_string(ip)]

                  _ ->
                    []
                end
              else
                []
              end
            end)
          else
            []
          end

        {:ok, ttl, ips}

      _ ->
        {:error, :invalid_packet}
    end
  end

  @doc """
  Extracts the minimum TTL from a DNS response packet.
  If the response is NXDOMAIN, returns 5.
  If the response is a successful resolution, parses answers and returns the minimum TTL,
  clamped between 5 and 3600 seconds.
  """
  def extract_min_ttl(packet) do
    case parse_response_metadata(packet, false) do
      {:ok, ttl, _ips} -> ttl
      {:error, _} -> 10
    end
  end

  @doc """
  Parses all resolved A (IPv4) or AAAA (IPv6) addresses from a DNS response packet
  and returns them as a list of IP address strings.
  """
  def extract_resolved_ips(packet) do
    case parse_response_metadata(packet, true) do
      {:ok, _ttl, ips} -> ips
      {:error, _} -> []
    end
  end

  defp ip_to_string(ip) do
    case :inet.ntoa(ip) do
      charlist when is_list(charlist) -> List.to_string(charlist)
      _ -> ""
    end
  end
end
