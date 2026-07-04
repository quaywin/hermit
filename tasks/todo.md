 # Todo List: Multi-Profile Dynamic DNS Filtering
 
 ## Phase 1: Database & Model Refactoring
 - [ ] Task 1.1: Add unique index on `dns_configs.inbound_profile_id` and update migrations.
 - [ ] Task 1.2: Refactor `DnsConfig`: replace `get_global/0` with `get_for_profile/1`.
 
 ## Phase 2: Dynamic Supervision & Registry Setup
 - [ ] Task 2.1: Add `Hermit.Vpn.DnsSupervisor` dynamic supervisor.
 - [ ] Task 2.2: Register `DnsWorker` and `Dns.Server` in registry using profile-specific keys.
 
 ## Phase 3: Isolated Network Namespace and Policy Routing
 - [ ] Task 3.1: Parameterize namespaces and interfaces.
 - [ ] Task 3.2: Implement host source policy routing rule setup and teardown.
 
 ## Phase 4: Parameterized UDP Packet Resolver
 - [ ] Task 4.1: Bind `Dns.Server` to dynamic host ports `5400 + profile_id`.
 - [ ] Task 4.2: Update packet log broadcast to emit to `dns_logs:profile_#{profile_id}`.
 
 ## Phase 5: UI & Integration
 - [ ] Task 5.1: Remove global DNS Control tab from LiveView.
 - [ ] Task 5.2: Add inline DNS controls & logs drawer to the Inbound Profiles view.
 
 ## Phase 6: Verification & Cleanup
 - [ ] Task 6.1: Update unit and LiveView integration tests.
 - [ ] Task 6.2: Validate all test suites pass.
