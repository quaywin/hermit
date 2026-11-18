defmodule Hermit.Vpn.SniParserTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.SniProxy.Parser

  describe "extract_tls_sni/1" do
    test "correctly extracts SNI from valid TLS ClientHello" do
      packet = build_tls_client_hello("netflix.com")
      assert Parser.extract_tls_sni(packet) == {:ok, "netflix.com"}
      assert Parser.extract_host(packet) == {:ok, "netflix.com"}
    end

    test "correctly normalizes uppercase hostname to lowercase" do
      packet = build_tls_client_hello("CHATGPT.COM")
      assert Parser.extract_tls_sni(packet) == {:ok, "chatgpt.com"}
      assert Parser.extract_host(packet) == {:ok, "chatgpt.com"}
    end

    test "returns error on non-TLS or malformed packet" do
      assert Parser.extract_tls_sni("random binary data not tls") ==
               {:error, :not_tls_client_hello}

      assert Parser.extract_tls_sni(
               <<0x16, 0x03, 0x01, 0x00, 0x05, 0x02, 0x00, 0x00, 0x01, 0x00>>
             ) ==
               {:error, :not_tls_client_hello}
    end
  end

  describe "extract_http_host/1" do
    test "correctly extracts Host from HTTP 1.1 GET request" do
      http_req = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n"
      assert Parser.extract_http_host(http_req) == {:ok, "example.com"}
      assert Parser.extract_host(http_req) == {:ok, "example.com"}
    end

    test "strips port number if present in Host header" do
      http_req = "POST /api/v1 HTTP/1.1\r\nHost: api.openai.com:80\r\nContent-Length: 0\r\n\r\n"
      assert Parser.extract_http_host(http_req) == {:ok, "api.openai.com"}
      assert Parser.extract_host(http_req) == {:ok, "api.openai.com"}
    end

    test "handles case-insensitive host header" do
      http_req = "HEAD / HTTP/1.1\r\nhost: bbc.co.uk\r\n\r\n"
      assert Parser.extract_http_host(http_req) == {:ok, "bbc.co.uk"}
    end

    test "returns error on non-HTTP binary" do
      assert Parser.extract_http_host("UNKNOWN PROTOCOL BYTES") == {:error, :not_http_request}
    end
  end

  defp build_tls_client_hello(hostname) do
    host_bytes = hostname
    host_len = byte_size(host_bytes)
    server_name = <<0::8, host_len::16, host_bytes::binary>>
    server_name_list = <<byte_size(server_name)::16, server_name::binary>>

    # Extension 0x0000: SNI
    sni_ext = <<0x0000::16, byte_size(server_name_list)::16, server_name_list::binary>>
    # Dummy extension: 0x000d (signature algorithms)
    dummy_ext = <<0x000D::16, 2::16, 0x0403::16>>

    extensions = <<sni_ext::binary, dummy_ext::binary>>
    extensions_block = <<byte_size(extensions)::16, extensions::binary>>

    random = :crypto.strong_rand_bytes(32)
    ciphers = <<0x1301::16, 0xC02F::16>>
    cipher_block = <<byte_size(ciphers)::16, ciphers::binary>>
    compression_block = <<1::8, 0::8>>
    session_id_block = <<0::8>>

    client_hello_body = <<
      0x0303::16,
      random::binary,
      session_id_block::binary,
      cipher_block::binary,
      compression_block::binary,
      extensions_block::binary
    >>

    handshake = <<0x01::8, byte_size(client_hello_body)::24, client_hello_body::binary>>
    <<0x16::8, 0x0301::16, byte_size(handshake)::16, handshake::binary>>
  end
end
