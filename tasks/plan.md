# Technical Implementation Plan: ControlD-like DNS Control

We will implement this feature in a series of logical phases, moving from database & backend config to the DNS proxy implementation, UDP log receiver, and finally the LiveView frontend.

## Implementation Order
1. **Migration & DB Models**: Add `dns_config` to `vpn_pairs` and support Ecto schema cast/validation.
2. **Elixir Log Receiver**: Create `Hermit.Vpn.DnsLogReceiver` to listen on UDP port `5300` and stream logs using Phoenix.PubSub.
3. **Python DNS Server Daemon**: Create a pure Python script (`priv/scripts/dns_server.py`) that acts as a DNS proxy/filter.
4. **Integration in PairWorker**: Modify `PairWorker`, `WireGuard` and `Local` modules to:
   - Route namespace DNS to `127.0.0.1`.
   - Write `/app/storage/<id>/dns_rules.json` on start/update.
   - Start/stop python daemon in network namespace.
   - Provide a simulator for mock mode.
5. **LiveView UI**:
   - Add a "DNS Control" tab in `lib/hermit_web/live/tunnel_detail_live.html.heex`.
   - Handle toggling filtering, checking categories, adding/deleting custom rules, and changing upstream DNS.
   - Subscribe to DNS log PubSub and stream logs in real-time.
6. **Testing**: Implement unit/integration tests to guarantee correctness.

## Risks & Mitigations
- **Port 53 binding**: Binding port 53 inside the namespace requires root. Hermit already runs as `privileged: true` so this is supported.
- **Python availability**: If python is missing in the production runner container, we will modify the Dockerfile to include `python3`.
- **Performance/Leaking**: If python fails or crashes, DNS requests would fail. We'll set up the Python process as a supervised daemon in PairWorker using a Port so it automatically stops/restarts with the pair worker.
