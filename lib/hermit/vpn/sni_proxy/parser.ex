defmodule Hermit.Vpn.SniProxy.Parser do
  @moduledoc """
  Extracts target hostname from TLS ClientHello (SNI extension) or HTTP Host header
  without terminating or decrypting the underlying TLS session.
  """

  @type parse_result :: {:ok, String.t()} | {:error, atom()}

  @doc """
  Inspects the initial packet bytes and extracts the hostname.
  Tries TLS ClientHello (SNI) first; if that fails or is not TLS, tries HTTP Host header.
  """
  @spec extract_host(binary()) :: parse_result()
  def extract_host(packet) when is_binary(packet) do
    case extract_tls_sni(packet) do
      {:ok, hostname} ->
        {:ok, hostname}

      {:error, _tls_reason} ->
        extract_http_host(packet)
    end
  end

  @doc """
  Extracts the Server Name Indication (SNI) from a TLS ClientHello packet.
  """
  @spec extract_tls_sni(binary()) :: parse_result()
  def extract_tls_sni(
        <<0x16::8, 0x03::8, _minor::8, _record_len::16, 0x01::8, _hello_len::24, _client_ver::16,
          _random::binary-size(32), session_id_len::8, _session_id::binary-size(session_id_len),
          cipher_suites_len::16, _cipher_suites::binary-size(cipher_suites_len),
          comp_methods_len::8, _comp_methods::binary-size(comp_methods_len), extensions_len::16,
          extensions::binary-size(extensions_len), _rest::binary>>
      ) do
    parse_extensions(extensions)
  end

  def extract_tls_sni(
        <<0x16::8, 0x03::8, _minor::8, _record_len::16, 0x01::8, _hello_len::24, _client_ver::16,
          _random::binary-size(32), session_id_len::8, _session_id::binary-size(session_id_len),
          cipher_suites_len::16, _cipher_suites::binary-size(cipher_suites_len),
          comp_methods_len::8, _comp_methods::binary-size(comp_methods_len)>>
      ) do
    # No extensions present
    {:error, :no_extensions}
  end

  def extract_tls_sni(_other), do: {:error, :not_tls_client_hello}

  defp parse_extensions(<<>>), do: {:error, :sni_not_found}

  defp parse_extensions(
         <<0x00::8, 0x00::8, ext_len::16, ext_data::binary-size(ext_len), _rest::binary>>
       ) do
    # Extension 0x0000: Server Name Indication
    case ext_data do
      <<_list_len::16, 0x00::8, name_len::16, hostname::binary-size(name_len), _::binary>> ->
        clean_host = hostname |> String.trim() |> String.downcase()

        if clean_host != "" do
          {:ok, clean_host}
        else
          {:error, :empty_sni}
        end

      _ ->
        {:error, :malformed_sni}
    end
  end

  defp parse_extensions(
         <<_other_type::16, ext_len::16, _ext_data::binary-size(ext_len), rest::binary>>
       ) do
    parse_extensions(rest)
  end

  defp parse_extensions(_malformed), do: {:error, :malformed_extensions}

  @doc """
  Extracts Host header from plain HTTP 1.0 / 1.1 request bytes.
  """
  @spec extract_http_host(binary()) :: parse_result()
  def extract_http_host(packet) when is_binary(packet) do
    lines = String.split(packet, ["\r\n", "\n"], parts: 20)

    case lines do
      [first_line | headers] ->
        if http_request_line?(first_line) do
          find_host_header(headers)
        else
          {:error, :not_http_request}
        end

      _ ->
        {:error, :not_http_request}
    end
  end

  defp http_request_line?(line) do
    upper = String.upcase(line)

    String.starts_with?(upper, "GET ") or String.starts_with?(upper, "POST ") or
      String.starts_with?(upper, "HEAD ") or String.starts_with?(upper, "PUT ") or
      String.starts_with?(upper, "DELETE ") or String.starts_with?(upper, "OPTIONS ") or
      String.starts_with?(upper, "CONNECT ")
  end

  defp find_host_header([]), do: {:error, :host_header_not_found}

  defp find_host_header([header | rest]) do
    trimmed = String.trim(header)

    if String.downcase(trimmed) |> String.starts_with?("host:") do
      case String.split(trimmed, ":", parts: 2) do
        [_, host_value] ->
          # Clean whitespace and strip port if present: e.g. "example.com:80" -> "example.com"
          host =
            host_value
            |> String.trim()
            |> String.split(":")
            |> List.first()
            |> String.downcase()

          if host != "" do
            {:ok, host}
          else
            find_host_header(rest)
          end

        _ ->
          find_host_header(rest)
      end
    else
      find_host_header(rest)
    end
  end
end
