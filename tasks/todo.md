# Tasks: ControlD-like DNS Control

- [x] Task 1: Add `dns_config` to `vpn_pairs` Table
  - Acceptance: A new migration is added; `vpn_pairs` has a JSON/Map `dns_config` field. Schema casting/validation in `VpnPair` works with defaults.
  - Verify: Run `mix ecto.migrate` and run a schema test.
  - Files: `lib/hermit/vpn/vpn_pair.ex`, new migration file.

- [x] Task 2: Implement Elixir UDP DnsLogReceiver
  - Acceptance: A GenServer starts on port `5300` (or configured) and listens for UDP packets. When it receives a JSON log packet, it publishes it to Phoenix.PubSub. It keeps a rolling list of the last 100 queries in state/ETS.
  - Verify: Start the receiver and send a test UDP packet; verify PubSub message received.
  - Files: `lib/hermit/vpn/dns_log_receiver.ex`, `lib/hermit/application.ex`.

- [x] Task 3: Implement Python DNS Proxy Daemon
  - Acceptance: A pure Python 3 script `priv/scripts/dns_server.py` runs, parses A/AAAA DNS requests, checks blocks (Ads/Adult lists and custom rules), redirects custom IPs, forwards other requests to upstream, and sends log packets via UDP.
  - Verify: Run python script locally, run `dig @127.0.0.1 -p <port> google.com` and verify response + log sent.
  - Files: `priv/scripts/dns_server.py`.

- [x] Task 4: Integrate DNS Daemon into PairWorker lifecycle
  - Acceptance: In real mode, when a tunnel starts and DNS filtering is enabled, PairWorker generates `dns_rules.json`, configures namespace resolv.conf to `127.0.0.1`, and launches the python daemon inside the namespace. In mock mode, PairWorker mocks resolution logs.
  - Verify: Run mock tests to ensure PairWorker starts/stops without crashing and mocks logs properly.
  - Files: `lib/hermit/vpn/pair_worker.ex`, `lib/hermit/vpn/outbound/wireguard.ex`, `lib/hermit/vpn/outbound/local.ex`.

- [/] Task 5: Design and Implement DNS Tab in Tunnel Detail UI
  - Acceptance: "DNS Control" tab added. Contains DNS status, checklist of blocking categories, inline custom rules list (with add/delete actions), upstream DNS input, and a beautiful scrolling real-time query log box.
  - Verify: Navigate to a tunnel detail page, toggle DNS filtering, add/delete rules, and see mock/real logs stream live.
  - Files: `lib/hermit_web/live/tunnel_detail_live.ex`, `lib/hermit_web/live/tunnel_detail_live.html.heex`.

- [ ] Task 6: Add Tests & Verify End-to-End
  - Acceptance: Unit and integration tests cover DNS config changes, log receiver, and PairWorker lifecycle. Dockerfile is modified to ensure python3 is installed.
  - Verify: Run `mix test` and `mix precommit`.
  - Files: `test/hermit/vpn/dns_test.exs`, `Dockerfile`.
