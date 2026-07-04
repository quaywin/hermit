 # Implementation Plan: Multi-Profile Dynamic DNS Filtering
 
 ## Overview
 Transition the single global DNS Filtering Node to a multi-profile dynamic DNS system where each Inbound Profile of type Tailscale can run its own independent DNS resolver in an isolated namespace.
 
 ## Architectural Decisions
 - **Subnet Routing:** Use policy-based routing on the host to route DNS responses to the correct namespace, preventing overlapping Tailscale subnets from colliding.
 - **Dynamic OTP Processes:** Use `Registry` to dynamically register GenServers for each profile. A `DynamicSupervisor` will manage worker Lifecycles.
 - **UX Integration:** Embed the DNS configuration panel directly within the Inbound Profile details panel in the UI.
 
 ## Task List
 
 ### Phase 1: Database & Model Refactoring
 - [ ] Task 1.1: Create unique index migration for `dns_configs.inbound_profile_id`.
 - [ ] Task 1.2: Refactor `DnsConfig` model: replace `get_global/0` with `get_for_profile/1`, preloading profile associations.
 
 ### Phase 2: Dynamic Supervision & Registry Setup
 - [ ] Task 2.1: Add `Hermit.Vpn.DnsSupervisor` to start and stop DNS components dynamically.
 - [ ] Task 2.2: Register processes using registry tuples like `{:via, Registry, {Hermit.Vpn.Registry, {:dns_worker, profile_id}}}`.
 
 ### Phase 3: Isolated Network Namespace and Policy Routing
 - [ ] Task 3.1: Parameterize namespace naming, interfaces, and subnets in `DnsWorker`.
 - [ ] Task 3.2: Implement host source policy routing rule setup and teardown (`ip rule` and `ip route`).
 
 ### Phase 4: Parameterized UDP Packet Resolver
 - [ ] Task 4.1: Bind `Dns.Server` to dynamic host ports `5400 + profile_id`.
 - [ ] Task 4.2: Update packet log broadcast to emit to `dns_logs:profile_#{profile_id}`.
 
 ### Phase 5: UI & Integration
 - [ ] Task 5.1: Remove global DNS Control tab from `dashboard_live.html.heex`.
 - [ ] Task 5.2: Add inline DNS controls & logs drawer to the Inbound Profiles view.
 
 ### Phase 6: Verification & Cleanup
 - [ ] Task 6.1: Update unit and LiveView integration tests to spawn multiple DNS profiles.
 - [ ] Task 6.2: Validate all 55+ tests run successfully.
