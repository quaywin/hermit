defmodule Hermit.Dns.PacketTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.Packet

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
    # Question section for test.com
    qname = <<4>> <> "test" <> <<3>> <> "com" <> <<0>>
    question = qname <> <<0x00, 0x01, 0x00, 0x01>>

    resp = Packet.build_nxdomain(id, question)
    assert byte_size(resp) == 12 + byte_size(question)

    # Check flags in the response header (offset 2-4)
    # response should have QR=1, Opcode=0, AA=1, TC=0, RD=1, RA=1, Z=0, RCODE=3 (NXDOMAIN)
    # flags binary is <<0x81, 0x83>>
    assert binary_part(resp, 2, 2) == <<0x81, 0x83>>
  end

  test "builds a valid A redirect response packet" do
    id = <<0x99, 0x99>>
    qname = <<4>> <> "test" <> <<3>> <> "com" <> <<0>>
    question = qname <> <<0x00, 0x01, 0x00, 0x01>>

    resp = Packet.build_a_response(id, question, "10.0.0.99")

    # Check header details: ID (0x9999), Flags (0x8180 - Response, No Error), QDCount=1, ANCount=1
    assert binary_part(resp, 0, 2) == id
    assert binary_part(resp, 2, 2) == <<0x81, 0x80>>
    assert binary_part(resp, 4, 4) == <<0x00, 0x01, 0x00, 0x01>>

    # Ensure the IP address "10.0.0.99" is embedded at the end of response (RDATA)
    # Resp has Header(12) + Question + AnswerRR(16) -> RDATA is last 4 bytes
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
    qname = <<4>> <> "test" <> <<3>> <> "com" <> <<0>>
    question = qname <> <<0x00, 0x01, 0x00, 0x01>>

    packet_bin = Packet.build_nxdomain(id, question)

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

    assert Packet.extract_resolved_ips(packet_bin) == ["142.250.190.46", "2001:db8:0:0:0:0:0:1"]
  end
end
