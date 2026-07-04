 # Spec: Multi-Profile Dynamic DNS Filtering System
 
 ## Objective
 Transition the centralized DNS filtering node into a dynamic, profile-specific system. Each Tailscale Inbound Profile will have its own independent DNS server and network namespace.
 
 ### User Stories & Use Cases
 - As an administrator, I want to configure separate DNS blocklists (e.g. ad blocking, adult content blocking) and custom rules for different Tailscale profiles.
 - As a user, I want client devices connected to Profile A's Tailnet to use Profile A's DNS Node, and clients on Profile B's Tailnet to use Profile B's DNS Node without routing conflicts.
 - Each profile must have its own isolated namespace, Tailscale login credentials, and dynamic Elixir UDP resolver process.
 
 ## Tech Stack
 - Language/Framework: Elixir 1.15+, Phoenix 1.7+ (LiveView)
 - Database: SQLite (via Ecto)
 - Networking: Linux network namespaces (`ip netns`), `iptables` for DNAT, source policy routing (`ip rule`) for conflict-free output routing.
 
 ## Architecture & Design
 
 ### 1. Database Schema
 - Modify `dns_configs` to have a strict 1-to-1 relationship with `inbound_profiles` instead of being global.
 - Foreign key constraint: `dns_configs.inbound_profile_id` is unique and required.
 - Query helper: `DnsConfig.get_for_profile(profile_id)` creates a configuration with default values if not present.
 
 ### 2. Networking & Namespaces (Multi-Tenant Routing)
 - Namespace name: `hermit_dns_#{profile_id}`.
 - Host veth interface: `dns_h_#{profile_id}`; Namespace veth interface: `eth0`.
 - Subnet allocation: `10.200.#{profile_id}.0/30`.
   - Host IP: `10.200.#{profile_id}.1`.
   - Namespace IP: `10.200.#{profile_id}.2`.
 - Host routing: Since multiple namespaces will have overlapping Tailscale IPs (`100.64.0.0/10`), we use source-policy routing to direct replies from the host back through the correct tunnel:
   - `ip rule add from 10.200.#{profile_id}.1 table 100#{profile_id}`
   - `ip route add default via 10.200.#{profile_id}.2 dev dns_h_#{profile_id} table 100#{profile_id}`
 - DNAT Redirection:
   - Inside namespace, redirect port 53 traffic to the host port:
     `iptables -t nat -A PREROUTING -p udp --dport 53 -j DNAT --to-destination 10.200.#{profile_id}.1:#{5400 + profile_id}`
 
 ### 3. OTP Process Supervision
 - Add `Hermit.Vpn.DnsSupervisor` (a `DynamicSupervisor`) to supervise profile-specific processes.
 - For each enabled DNS profile, spawn:
   - `Hermit.Vpn.DnsWorker` (via registry key `{:dns_worker, profile_id}`) to manage namespace lifecycle and `tailscaled`.
   - `Hermit.Dns.Server` (via registry key `{:dns_server, profile_id}`) to listen on port `5400 + profile_id` and filter incoming queries.
 
 ### 4. UI Layout
 - Remove the global "DNS Control" tab.
 - Embed DNS settings and query logs directly in the **Inbound Profiles** tab (as a toggleable section or a details view modal) so that DNS configuration is colocated with credentials.
 
 ## Testing Strategy
 - Unit tests for dynamic routing calculations (subnet, ports, table IDs).
 - Integration tests with dynamic supervisor spawning and state verification.
 - Simulated log receiver test verifying logs are broadcasted to the profile's channel (`dns_logs:#{profile_id}`).
 
 ## Boundaries
 - **Always:** Clean up Linux routing rules, iptables, and namespaces on GenServer termination.
 - **Ask first:** Modifying global iptables forward rules or registry keys.
 - **Never:** Allow hardcoded port numbers or overlapping subnets.
