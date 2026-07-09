# Run this script using:
# docker exec -it hermit_orchestrator_dev elixir scratch_test_doh_proxy.exs

# 1. Cấu hình HTTP Proxy (Cổng HTTP Proxy của VPN Pair đang chạy)
# Bạn hãy khởi động 1 VPN Pair trên Dashboard Hermit và thay đổi cổng này tương ứng
proxy_port = 10001 
proxy_url = "http://127.0.0.1:#{proxy_port}"

send_query_via_proxy = fn domain ->
  # Build DNS query packet (Transaction ID: 12, Type: A)
  labels = String.split(domain, ".")
  qname = Enum.map(labels, fn label -> <<byte_size(label)>> <> label end) |> Enum.join()
  qname = qname <> <<0>>
  query_packet = <<0, 12, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>

  doh_url = "https://cloudflare-dns.com/dns-query"
  IO.puts("Querying: #{domain} via proxy #{proxy_url} ...")

  # Sử dụng Req với cấu hình proxy
  case Req.post(doh_url,
         body: query_packet,
         headers: [
           {"content-type", "application/dns-message"},
           {"accept", "application/dns-message"}
         ],
         connect_options: [
           proxy: {:http, proxy_url}
         ]
       ) do
    {:ok, %{status: 200, body: body}} ->
      IO.puts("  Success! Status 200, response size: #{byte_size(body)} bytes.")
      # In gói tin DNS thô dạng binary để kiểm tra
      IO.inspect(body, label: "  DNS raw response")

    {:ok, %{status: status, body: body}} ->
      IO.puts("  Failed! Status: #{status}")
      IO.inspect(body)

    {:error, reason} ->
      IO.puts("  Error: #{inspect(reason)}")
  end
end

# Thử truy vấn domain
send_query_via_proxy.("google.com")
