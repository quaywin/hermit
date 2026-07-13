# A helper to send DoH query
send_query = fn domain ->
  # Build DNS query packet
  labels = String.split(domain, ".")
  qname = Enum.map(labels, fn label -> <<byte_size(label)>> <> label end) |> Enum.join()
  qname = qname <> <<0>>

  # Transaction ID 12, Standard query with recursion desired, 1 question, type A, class IN
  query_packet = <<0, 12, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>

  url = "http://localhost:3000/dns-query/8gNujQ"
  IO.puts("Querying: #{domain} ...")

  case Req.post(url,
         body: query_packet,
         headers: [{"content-type", "application/dns-message"}]
       ) do
    {:ok, %{status: 200, body: body}} ->
      IO.puts("  Success! Status 200, response size: #{byte_size(body)} bytes.")

    {:ok, %{status: status, body: body}} ->
      IO.puts("  Failed! Status: #{status}")
      IO.inspect(body)

    {:error, reason} ->
      IO.puts("  Error: #{inspect(reason)}")
  end
end

# Send queries for multiple domains
domains = ["google.com", "facebook.com", "blocked.com", "news.ycombinator.com", "github.com"]

for d <- domains do
  send_query.(d)
  :timer.sleep(500)
end
