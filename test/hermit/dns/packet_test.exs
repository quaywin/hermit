defmodule Hermit.Dns.PacketTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.Packet
  require Record

  Record.defrecord(:dns_query, Record.extract(:dns_query, from_lib: "dns_erlang/include/dns.hrl"))

  Record.defrecord(
    :dns_message,
    Record.extract(:dns_message, from_lib: "dns_erlang/include/dns.hrl")
  )

  Record.defrecord(:dns_optrr, Record.extract(:dns_optrr, from_lib: "dns_erlang/include/dns.hrl"))

  Record.defrecord(
    :dns_opt_ecs,
    Record.extract(:dns_opt_ecs, from_lib: "dns_erlang/include/dns.hrl")
  )

  test "parses a standard DNS query binary successfully" do
    # Transaction ID: 0x1234, Flags: 0x0100 (RD=1), Questions=1, Answer/Authority/Additional=0
    # Query: google.com (type A, class IN)
    # google.com in label format: 6 "google" 3 "com" 0 -> \x06google\x03com\x00
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    # A
    qtype = <<0x00, 0x01>>
    # IN
    qclass = <<0x00, 0x01>>

    packet_bin =
      <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
        qname <> qtype <> qclass

    assert {:ok, query} = Packet.parse(packet_bin)
    assert query.id == <<0x12, 0x34>>
    assert query.domain == "google.com"
    assert query.qtype == :A
    assert query.qclass == 1
  end

  test "builds a valid NXDOMAIN response packet" do
    id = <<0x55, 0xAA>>
    query_rec = dns_query(name: "test.com", class: 1, type: 1)

    resp = Packet.build_nxdomain(id, query_rec)

    # Check flags in the response header (offset 2-4)
    # response should have QR=1, Opcode=0, AA=false, TC=0, RD=1, RA=1, Z=0, RCODE=3 (NXDOMAIN)
    # flags binary is <<0x81, 0x83>>
    assert binary_part(resp, 2, 2) == <<0x81, 0x83>>
  end

  test "builds a valid A redirect response packet" do
    id = <<0x99, 0x99>>
    query_rec = dns_query(name: "test.com", class: 1, type: 1)

    resp = Packet.build_a_response(id, query_rec, "10.0.0.99")

    # Check header details: ID (0x9999), Flags (0x8180 - Response, No Error), QDCount=1, ANCount=1
    assert binary_part(resp, 0, 2) == id
    assert binary_part(resp, 2, 2) == <<0x81, 0x80>>
    assert binary_part(resp, 4, 4) == <<0x00, 0x01, 0x00, 0x01>>

    # Ensure the IP address "10.0.0.99" is embedded at the end of response (RDATA)
    # Resp has Header(12) + Question + AnswerRR -> RDATA is last 4 bytes
    assert binary_part(resp, byte_size(resp) - 4, 4) == <<10, 0, 0, 99>>
  end

  test "extracts minimum TTL from a standard successful DNS response packet" do
    id = <<0x12, 0x34>>
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    qtype = <<0, 1>>
    qclass = <<0, 1>>
    question = qname <> qtype <> qclass

    # TTL is 300 seconds (0x0000012C)
    # Answer record uses a name pointer to offset 12 (0xC00C)
    answer =
      <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 142, 250, 190,
        46>>

    # 1 Question, 1 Answer, 0 Authority, 0 Additional
    # Flags: 0x8180 (Response, RD=1, RA=1, Rcode=0)
    packet_bin =
      <<id::binary, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>> <>
        question <> answer

    assert Packet.extract_min_ttl(packet_bin) == 300
  end

  test "extracts TTL from a response with NXDOMAIN" do
    id = <<0x55, 0xAA>>
    query_rec = dns_query(name: "test.com", class: 1, type: 1)

    packet_bin = Packet.build_nxdomain(id, query_rec)

    assert Packet.extract_min_ttl(packet_bin) == 5
  end

  test "extracts resolved IPv4 and IPv6 addresses from a response packet" do
    id = <<0x12, 0x34>>
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    question = qname <> <<0, 1, 0, 1>>

    # A Record with 142.250.190.46
    answer_a =
      <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 142, 250, 190,
        46>>

    # AAAA Record with 2001:db8::1 (2001:0db8:0000:0000:0000:0000:0000:0001)
    # RDATA length is 16 bytes
    # Type 28 (0x001C)
    answer_aaaa =
      <<0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x10, 0x20, 0x01, 0x0D,
        0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01>>

    # 1 Question, 2 Answers
    packet_bin =
      <<id::binary, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00>> <>
        question <> answer_a <> answer_aaaa

    assert Packet.extract_resolved_ips(packet_bin) == ["142.250.190.46", "2001:db8::1"]
  end

  test "correctly parses and formats new DNS qtypes" do
    # Test qtype_to_string/1 directly
    assert Packet.qtype_to_string(:HTTPS) == "HTTPS"
    assert Packet.qtype_to_string(:SVCB) == "SVCB"
    assert Packet.qtype_to_string(:SRV) == "SRV"
    assert Packet.qtype_to_string(:CAA) == "CAA"
    assert Packet.qtype_to_string(:ANY) == "ANY"

    # Test parse query with TYPE_65 (HTTPS)
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    # 65 in hex
    qtype_https = <<0x00, 0x41>>
    qclass = <<0x00, 0x01>>

    packet_bin =
      <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
        qname <> qtype_https <> qclass

    assert {:ok, query} = Packet.parse(packet_bin)
    assert query.qtype == :HTTPS
    assert Packet.qtype_to_string(query.qtype) == "HTTPS"
  end

  test "patch_rcode/2 handles extremely short packets without crashing" do
    # Empty packet
    assert Packet.patch_rcode(<<>>, 2) == <<>>
    # 2 bytes packet (only ID)
    assert Packet.patch_rcode(<<0x12, 0x34>>, 2) == <<0x12, 0x34>>
    # 3 bytes packet
    assert Packet.patch_rcode(<<0x12, 0x34, 0x56>>, 2) == <<0x12, 0x34, 0x56>>
  end

  test "patch_stale_ttl/2 updates TTL of answers in response packet" do
    id = <<0x12, 0x34>>
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    qtype = <<0, 1>>
    qclass = <<0, 1>>
    question = qname <> qtype <> qclass

    # Original TTL is 300 seconds (0x0000012C)
    answer =
      <<0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 142, 250, 190,
        46>>

    packet_bin =
      <<id::binary, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>> <>
        question <> answer

    # Update TTL to 30s
    patched = Packet.patch_stale_ttl(packet_bin, 30)

    # Check that minimum TTL extracted is now 30
    assert Packet.extract_min_ttl(patched) == 30
  end

  test "inject_ecs/3 successfully injects ECS option into query packet with fallback" do
    id = 0x1234
    query_rec = dns_query(name: "google.com", class: 1, type: 1)
    query_packet = Packet.build_query_packet(id, query_rec)

    # 1. Inject public IPv4 client IP -> should inject client IP directly
    client_ip_v4 = {14, 162, 50, 99}
    assert {:ok, injected_v4} = Packet.inject_ecs(query_packet, client_ip_v4, {8, 8, 8, 8})

    assert msg_v4 = :dns.decode_message(injected_v4)
    additional_v4 = dns_message(msg_v4, :additional)
    assert [opt_v4] = Enum.filter(additional_v4, &Record.is_record(&1, :dns_optrr))
    opts_v4 = dns_optrr(opt_v4, :data)
    assert [ecs_v4] = Enum.filter(opts_v4, &Record.is_record(&1, :dns_opt_ecs))
    assert dns_opt_ecs(ecs_v4, :address) == <<14, 162, 50>>

    # 2. Inject private IPv4 client IP without fallback -> should skip ECS (return query_packet unchanged)
    private_ip = {10, 0, 0, 5}
    assert {:ok, ^query_packet} = Packet.inject_ecs(query_packet, private_ip, nil)

    # 3. Inject private IPv4 client IP with public fallback IP -> should use fallback IP
    fallback_ip = {113, 160, 20, 1}
    assert {:ok, injected_fallback} = Packet.inject_ecs(query_packet, private_ip, fallback_ip)

    assert msg_fb = :dns.decode_message(injected_fallback)
    additional_fb = dns_message(msg_fb, :additional)
    assert [opt_fb] = Enum.filter(additional_fb, &Record.is_record(&1, :dns_optrr))
    opts_fb = dns_optrr(opt_fb, :data)
    assert [ecs_fb] = Enum.filter(opts_fb, &Record.is_record(&1, :dns_opt_ecs))
    assert dns_opt_ecs(ecs_fb, :address) == <<113, 160, 20>>

    # 4. Inject DoH 3-tuple format public IP
    doh_client_ip = {:doh, {14, 162, 50, 99}, "my-ios-device"}
    assert {:ok, injected_doh} = Packet.inject_ecs(query_packet, doh_client_ip, nil)

    assert msg_doh = :dns.decode_message(injected_doh)
    additional_doh = dns_message(msg_doh, :additional)
    assert [opt_doh] = Enum.filter(additional_doh, &Record.is_record(&1, :dns_optrr))
    opts_doh = dns_optrr(opt_doh, :data)
    assert [ecs_doh] = Enum.filter(opts_doh, &Record.is_record(&1, :dns_opt_ecs))
    assert dns_opt_ecs(ecs_doh, :address) == <<14, 162, 50>>
  end
end
