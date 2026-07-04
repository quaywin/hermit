defmodule Hermit.Dns.PacketTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.Packet

  test "parses a standard DNS query binary successfully" do
    # Transaction ID: 0x1234, Flags: 0x0100 (RD=1), Questions=1, Answer/Authority/Additional=0
    # Query: google.com (type A, class IN)
    # google.com in label format: 6 "google" 3 "com" 0 -> \x06google\x03com\x00
    qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
    qtype = <<0x00, 0x01>> # A
    qclass = <<0x00, 0x01>> # IN
    
    packet_bin = <<0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> qname <> qtype <> qclass

    assert {:ok, query} = Packet.parse(packet_bin)
    assert query.id == <<0x12, 0x34>>
    assert query.domain == "google.com"
    assert query.qtype == :A
    assert query.qclass == 1
  end

  test "builds a valid NXDOMAIN response packet" do
    id = <<0x55, 0xaa>>
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
end
