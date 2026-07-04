# Spec: ControlD-like DNS Control and Live Logs

## Objective
Enable a ControlD-like DNS control and filtering engine within Hermit. Every active VPN Pair can be configured with customized DNS rules, blocklists, and redirect mappings. All DNS queries made within a namespace are routed through a namespace-specific DNS proxy, resolved locally or forwarded securely, and logged in real-time to the dashboard.

### Core User Stories
- As a user, I want to enable or disable DNS filtering for any of my VPN Pairs.
- As a user, I want to block ads/trackers and adult content with simple toggle checkboxes.
- As a user, I want to define custom DNS rules to "Block" (NXDOMAIN), "Bypass" (force default resolve), or "Redirect" (resolve to a specific IP address) for specific domain names.
- As a user, I want to configure the Upstream DNS servers used by a VPN Pair.
- As a user, I want to see a live-scrolling, real-time log of all DNS queries made by a VPN Pair, indicating the domain name, record type, action taken (RESOLVED, BLOCKED, REDIRECTED), resolved IP/Target, and latency.

---

## Tech Stack
- **Elixir & OTP** (v1.18+): Backend core, PairWorker lifecycle, UDP query log receiver.
- **Phoenix LiveView** (v1.2+): Live dashboard, stream-based scrolling logs, reactive form management.
- **SQLite (Ecto)**: Persists configuration (`dns_config`) on VPN Pairs.
- **Python 3**: A lightweight, dependency-free DNS UDP proxy daemon running inside network namespaces.

---

## Commands
- **Run migrations**: `rtk mix ecto.migrate`
- **Run tests**: `rtk mix test`
- **Precommit checks**: `rtk mix precommit`

---

## Project Structure
We will add and modify the following files:
- `priv/repo/migrations/*_add_dns_config_to_vpn_pairs.exs` -> Migration adding `:dns_config` map field to `vpn_pairs`.
- `lib/hermit/vpn/vpn_pair.ex` -> Extend model schema to cast and validate `:dns_config`.
- `lib/hermit/vpn/dns_server.ex` -> Python script generator or template containing the Python UDP DNS server.
- `lib/hermit/vpn/dns_log_receiver.ex` -> GenServer receiving UDP log messages from DNS proxies.
- `lib/hermit/vpn/pair_worker.ex` -> Lifecycle hooks to generate config, write rules, start/stop python DNS daemon inside namespace.
- `lib/hermit/vpn/outbound/wireguard.ex` and `local.ex` -> Route namespace resolver to `127.0.0.1` when DNS control is enabled.
- `lib/hermit_web/live/tunnel_detail_live.ex` -> LiveView event handlers for saving DNS settings, toggles, custom rules, and streaming query logs.
- `lib/hermit_web/live/tunnel_detail_live.html.heex` -> UI changes for the DNS control tab.
- `test/hermit/vpn/dns_test.exs` -> Unit tests for the DNS config, validation, and logs.

---

## Code Style

### Elixir Style
Use clear Ecto pattern matches and functional piping:
```elixir
def handle_info({:udp, _socket, _ip, _port, data}, state) do
  case Jason.decode(data) do
    {:ok, %{"pair_id" => id} = log} ->
      Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{id}", {:dns_log, log})
      {:noreply, state}
    _ ->
      {:noreply, state}
  end
end
```

### Python Style
Use standard, clean Python 3 with type hinting and zero external dependencies:
```python
import socket
import sys

def parse_domain(data: bytes, offset: int = 12) -> tuple[str, int, int]:
    labels = []
    while True:
        length = data[offset]
        if length == 0:
            offset += 1
            break
        labels.append(data[offset+1 : offset+1+length].decode('utf-8', errors='ignore'))
        offset += 1 + length
    domain = '.'.join(labels)
    qtype = int.from_bytes(data[offset : offset+2], byteorder='big')
    return domain, qtype, offset + 4
```

---

## Testing Strategy
- **Unit Tests**:
  - Test `VpnPair.changeset` with valid/invalid `dns_config` structures.
  - Test `DnsLogReceiver` UDP packet decoding and PubSub broadcasting.
- **Integration/Mock Tests**:
  - Verify that `PairWorker` writes DNS configuration to files and launches the daemon (with proper command mocking).
  - Verify the LiveView logs stream via mock log triggers.

---

## Boundaries
- **Always do**: Run in mock mode on macOS. Write clean, standard Python that handles parsing exceptions gracefully.
- **Ask first**: Large database schema alterations beyond adding the config field.
- **Never do**: Add massive external packages/dependencies for DNS or Python (e.g. `dnspython`, `dnsmasq` package installs) unless strictly required. Stick to standard library solutions for simplicity and portability.

---

## Success Criteria
- [ ] Database schema updated; `dns_config` can be saved and retrieved.
- [ ] Python DNS daemon (`dns_server.py`) successfully parses UDP DNS requests, checks blocklists/redirects, resolves upstreams via namespace default routes, and sends JSON log messages back to the host.
- [ ] A global Elixir UDP server binds to host port `5300` and relays DNS log messages to the corresponding LiveView channel via Phoenix PubSub.
- [ ] The Tunnel Detail page features a "DNS Control" tab containing:
  - Toggle switch for DNS Filtering status.
  - Category filters (Ads/Trackers, Adult Content).
  - Custom rules table to block, bypass, or redirect domains.
  - Real-time scrolling query log with status indicators.
- [ ] All existing 45 tests and new DNS tests pass.

---

## Open Questions
1. How large should the built-in Ads/Trackers blocklist be?
   *Recommendation*: A tiny, high-impact built-in list of ~50 common domains, combined with user custom rules, to keep the footprint minimal.
2. Should we support DNS caching?
   *Recommendation*: Keep the Python script stateless and forward unresolved requests directly to the upstream DNS, relying on the upstream DNS (e.g. `1.1.1.1` or Google) for caching to ensure simplicity.
