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
    :dns_optrr,
    Record.extract(:dns_optrr, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(
    :dns_opt_ecs,
    Record.extract(:dns_opt_ecs, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(
    :dns_rrdata_a,
    Record.extract(:dns_rrdata_a, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(
    :dns_rrdata_aaaa,
    Record.extract(:dns_rrdata_aaaa, from_lib: "dns_erlang/include/dns.hrl")
  )

  @type qtype ::
          :A
          | :AAAA
          | :MX
          | :TXT
          | :CNAME
          | :NS
          | :PTR
          | :SOA
          | :HTTPS
          | :SVCB
          | :SRV
          | :CAA
          | :ANY
          | {:unknown, integer()}

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

  defp parse_query_fast(
         <<id::16, _rest_header::binary-size(10), question_section::binary>> = packet
       ) do
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
  defp to_qtype(65), do: :HTTPS
  defp to_qtype(64), do: :SVCB
  defp to_qtype(33), do: :SRV
  defp to_qtype(257), do: :CAA
  defp to_qtype(255), do: :ANY
  defp to_qtype(val), do: {:unknown, val}

  def qtype_to_string(:A), do: "A"
  def qtype_to_string(:AAAA), do: "AAAA"
  def qtype_to_string(:MX), do: "MX"
  def qtype_to_string(:TXT), do: "TXT"
  def qtype_to_string(:CNAME), do: "CNAME"
  def qtype_to_string(:NS), do: "NS"
  def qtype_to_string(:PTR), do: "PTR"
  def qtype_to_string(:SOA), do: "SOA"
  def qtype_to_string(:HTTPS), do: "HTTPS"
  def qtype_to_string(:SVCB), do: "SVCB"
  def qtype_to_string(:SRV), do: "SRV"
  def qtype_to_string(:CAA), do: "CAA"
  def qtype_to_string(:ANY), do: "ANY"
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
  Builds an empty response (NOERROR with 0 answers) for AAAA blocking.
  """
  def build_empty_response(id_bin, query_record)
      when Record.is_record(query_record, :dns_query) do
    id_val = parse_id_bin(id_bin)

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
        anc: 0,
        questions: [query_record],
        answers: []
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
        # Fallback to simple bitwise manipulation if decoding fails, checking length
        case packet do
          <<id::binary-size(2), _flags::binary-size(2), rest::binary>> ->
            flags2 = 0x80 + rcode
            <<id::binary, 0x81, flags2, rest::binary>>

          _ ->
            packet
        end
    end
  end

  @doc """
  Safely updates the TTL of all answer/authority/additional records in a raw DNS response packet.
  Used to set a short TTL (e.g. 30s) for stale cache responses according to RFC 8767.
  """
  def patch_stale_ttl(packet, target_ttl) do
    case :dns.decode_message(packet) do
      msg when Record.is_record(msg, :dns_message) ->
        answers = dns_message(msg, :answers)
        authority = dns_message(msg, :authority)
        additional = dns_message(msg, :additional)

        patched_answers = patch_rrs_ttl(answers, target_ttl)
        patched_authority = patch_rrs_ttl(authority, target_ttl)
        patched_additional = patch_rrs_ttl(additional, target_ttl)

        patched_msg =
          dns_message(msg,
            answers: patched_answers,
            authority: patched_authority,
            additional: patched_additional
          )

        :dns.encode_message(patched_msg)

      _ ->
        packet
    end
  end

  defp patch_rrs_ttl(rrs, target_ttl) when is_list(rrs) do
    Enum.map(rrs, fn rr ->
      if Record.is_record(rr, :dns_rr) do
        dns_rr(rr, ttl: target_ttl)
      else
        rr
      end
    end)
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

  @doc """
  Injects or updates the EDNS Client Subnet (ECS) option in a raw DNS query packet.
  `client_ip` can be an IP tuple (IPv4 or IPv6) or an IP address string.
  If the `client_ip` is private and `fallback_ip` is provided, `fallback_ip` will be used instead.
  If the `client_ip` is private and no `fallback_ip` is provided, ECS injection is skipped.
  """
  def inject_ecs(packet, client_ip, fallback_ip \\ nil) do
    with {:ok, ip_tuple} <- to_ip_tuple(client_ip) do
      if private_ip?(ip_tuple) do
        case to_ip_tuple(fallback_ip) do
          {:ok, fallback_tuple} ->
            do_inject_ecs(packet, fallback_tuple)

          _ ->
            # Private IP and no fallback -> Skip ECS entirely (return clean packet)
            {:ok, packet}
        end
      else
        do_inject_ecs(packet, ip_tuple)
      end
    else
      _ -> {:ok, packet}
    end
  end

  def private_ip?({127, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private_ip?({0xFC00, _, _, _, _, _, _, _}), do: true
  def private_ip?({0xFD00, _, _, _, _, _, _, _}), do: true
  def private_ip?(_), do: false

  defp to_ip_tuple({:doh, ip_tuple, _device_name}), do: to_ip_tuple(ip_tuple)
  defp to_ip_tuple(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8], do: {:ok, ip}

  defp to_ip_tuple(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  defp to_ip_tuple(_), do: :error

  defp do_inject_ecs(packet, ip_tuple) do
    case :dns.decode_message(packet) do
      msg when Record.is_record(msg, :dns_message) ->
        ecs_opt = build_ecs_record(ip_tuple)
        additional = dns_message(msg, :additional)

        # 1. Separate the existing OPT record from the additional section (if any)
        {optrr, other_additional} =
          case Enum.split_with(additional, &Record.is_record(&1, :dns_optrr)) do
            {[rr | _], rest} -> {rr, rest}
            {[], rest} -> {dns_optrr(udp_payload_size: 4096, data: []), rest}
          end

        # 2. Replace or prepend the new ECS option in the OPT record data list
        updated_data =
          Enum.reject(dns_optrr(optrr, :data), &Record.is_record(&1, :dns_opt_ecs)) ++ [ecs_opt]

        updated_optrr = dns_optrr(optrr, data: updated_data)
        updated_additional = [updated_optrr | other_additional]

        # 3. Re-encode the DNS packet with updated additional records count
        patched_msg =
          dns_message(msg,
            additional: updated_additional,
            adc: length(updated_additional)
          )

        {:ok, :dns.encode_message(patched_msg)}

      _ ->
        {:error, :invalid_packet}
    end
  end

  defp build_ecs_record({ip1, ip2, ip3, _ip4}) do
    # IPv4 /24 subnet (3 bytes)
    dns_opt_ecs(
      family: 1,
      source_prefix_length: 24,
      scope_prefix_length: 0,
      address: <<ip1, ip2, ip3>>
    )
  end

  defp build_ecs_record({ip1, ip2, ip3, _ip4, _ip5, _ip6, _ip7, _ip8}) do
    # IPv6 /48 subnet (3 blocks = 6 bytes)
    dns_opt_ecs(
      family: 2,
      source_prefix_length: 48,
      scope_prefix_length: 0,
      address: <<ip1::16, ip2::16, ip3::16>>
    )
  end

  defp build_ecs_record(client_ip) when is_binary(client_ip) do
    case :inet.parse_address(String.to_charlist(client_ip)) do
      {:ok, ip_tuple} ->
        build_ecs_record(ip_tuple)

      _ ->
        # Fallback to local subnet in case parsing fails
        dns_opt_ecs(
          family: 1,
          source_prefix_length: 24,
          scope_prefix_length: 0,
          address: <<127, 0, 0>>
        )
    end
  end

  defp build_ecs_record(_) do
    dns_opt_ecs(
      family: 1,
      source_prefix_length: 24,
      scope_prefix_length: 0,
      address: <<127, 0, 0>>
    )
  end
end
