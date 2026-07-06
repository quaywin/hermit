# Hermit

Hermit is a modular multi-tunnel orchestrator and manager for VPN connection pairs running inside isolated network namespaces (`netns`). It decouples configurations into reusable **Inbound Profiles** (e.g., SOCKS5/HTTP Proxy, Tailscale) and **Outbound Profiles** (e.g., WireGuard), allowing you to easily pair, share configurations, and manage multiple tunnels side-by-side.

The application provides a real-time web dashboard to monitor bandwidth usage, manage connection states, create and share profiles, and configure global settings.

> ⚠️ **IMPORTANT NOTE**: This project requires elevated system privileges (`privileged: true`) and advanced networking tools such as `iptables`, `iproute2`, `wireguard-tools`, and `tailscale`. To avoid impacting your host machine's network configuration and to ensure a consistent development environment, **it is highly recommended to develop and run this project completely within Docker**.

---

## Architecture & Network Flow

Hermit uses a decoupled architecture where a VPN tunnel (VPN Pair) is created by combining an **Inbound Profile** with an **Outbound Profile**. The architecture splits system operations into two separate, coordinated planes: the **Traffic Plane** (for normal internet data) and the **DNS Control Plane** (for name resolution and dynamic filtering).

### 1. Traffic Plane (General Data Flow)
This plane manages the encapsulation and transport of regular network traffic (HTTP, TCP/UDP streams) through isolated namespaces.

```mermaid
flowchart TD
    Client["Client / Host Application"] -->|"1. Request In"| Inbound["Inbound Profile <br/> SOCKS5/HTTP or Tailscale"]
    subgraph NetNS["VPN Pair Namespace (hermit_wg_pair_id)"]
        Inbound -->|"2. Internal Forwarding"| Outbound["Outbound Profile <br/> WireGuard wg0"]
    end
    Outbound -->|"3. Encrypted Tunnel Out"| Internet["VPN / External Internet"]
```

* **Inbound Profiles**: Define how traffic enters the isolated namespace.
  * **SOCKS5/HTTP Proxy**: Spawns dual proxy daemons (`microsocks` SOCKS5 on 1080, `tinyproxy` HTTP on 8080) inside the namespace, multiplexed via a host-level relayer.
  * **Tailscale**: Binds the namespace to your Tailscale network (tailnet) as an active node.
* **Outbound Profiles**: Define how traffic exits the namespace.
  * **WireGuard**: Interfaces are isolated inside the namespace (`wg0`) to route all outbound data through WireGuard.
* **VPN Pairs**: The orchestrator ties these components together into a single running instance, preventing resource conflicts automatically.

---

### 2. DNS Control Plane (Resolution & Filtering)
This plane is completely decoupled from the VPN Pairs. It manages name resolution, caching, and blocklist filtering through dedicated DNS Nodes tied to each **Inbound Profile** (specifically Tailscale profiles), avoiding the overhead of running a local resolver inside every single tunnel.

When DNS Filtering is enabled for an Inbound Profile, Hermit provisions a dedicated DNS namespace (`hermit_dns_{profile_id}`) running `tailscaled` as an active Tailscale node. When Tailscale DNS Override is enabled, the node's Tailscale IP is registered tailnet-wide via the Tailscale API, causing all DNS queries from any device on the tailnet to route automatically to it.

```mermaid
flowchart TD
    Client["Tailnet Device"] -->|"1. DNS Query"| TS

    subgraph DNS_NS["DNS Namespace (hermit_dns_profile_id)"]
        TS["tailscaled Node"]
    end

    subgraph Host["Host Plane (Container)"]
        Server["Elixir DNS Server"]
        Fast["Fast Path<br/>(Cache / Blocklist)"]
        Upstream["Upstream DNS / DoH"]
        Magic["Tailscale MagicDNS"]
    end

    TS -->|"2. Redirect (iptables)"| Server
    Server --> Fast
    Server --> Upstream
    Server --> Magic

    Fast -->|"Instant Return"| Client
    Upstream -->|"Cache & Return"| Server
    Magic -->|"Cache & Return"| Server
```

* **Tailscale Entry Point**: `tailscaled` inside the DNS namespace acts as the Tailscale network endpoint. DNS queries from any tailnet device arrive at `tailscaled`, which delivers them into the namespace's network stack. The kernel then hits `iptables PREROUTING DNAT` rules that redirect all UDP/TCP port 53 traffic to the Elixir DNS Server on the host via the virtual `veth` pair (`dns_h_{id}` on host side, `eth0` inside namespace).
* **Profile-Specific Filtering (Fast Path vs. Slow Path)**: The Elixir DNS Server on the host (bound to `10.251.{profile_id}.1` on port `5400 + profile_id`) evaluates each query in order:
  1. **Custom Rules**: Matched first. Domains matching a custom `block` rule get an immediate NXDOMAIN; domains matching a `redirect` rule get the configured IP.
  2. **Blocklists**: If no custom rule matched, the query is checked against AdGuard, GoodbyeAds, and adult content blocklists loaded into ETS. Matched domains get NXDOMAIN.
  3. **Cache**: If the query is not blocked, the shared ETS cache is checked. A cache hit returns the stored response immediately.
  4. Steps 1-3 are the **Fast Path** (0-1 ms, no external network access). A cache miss proceeds to the **Slow Path** (upstream forwarding).
* **Upstream Forwarding & MagicDNS**: On a cache miss, the server selects upstreams based on the domain:
  * Standard queries are forwarded to configured upstream DNS servers (UDP) or DNS-over-HTTPS (DoH) endpoints. The server probes all upstreams periodically and prefers the lowest-latency one.
  * Queries for Tailscale internal domains (`*.ts.net`, `*.tailscale.net`) are forwarded to the Tailscale nameserver `100.100.100.100`. Source-based policy routing on the host (`ip rule from 10.251.{id}.1 to 100.64.0.0/10 table {1000+id}`) routes these packets back through the veth into the DNS namespace, where `tailscaled` resolves them via MagicDNS. The response follows the same path in reverse.

---

## How Traffic and DNS Planes Connect

When you run a VPN Pair, its network namespace is configured as follows:

| Connection Feature | Plane / Mechanism | Network Route |
| :--- | :--- | :--- |
| **Web & API Traffic** | Traffic Plane | Routed directly through the outbound WireGuard (`wg0`) interface. |
| **DNS Queries** | DNS Control Plane | Resolved according to the VPN Pair's configuration: either routed over the Tailnet to the profile's dedicated DNS Node (when using Tailscale DNS integration) or resolved via custom DNS resolvers. |

---

## System Requirements

- **Docker** and **Docker Compose**
- There is no need to install Elixir, Erlang, or SQLite on your host machine as all runtime dependencies are packaged and configured automatically inside the container.

---

## Installation & Quick Start with Docker

Hermit can be run in two different modes:

### 1. Production Mode (Quickest - No Clone Required)
If you only want to run Hermit without downloading the entire source code repository:

1. Download the `docker-compose.yml` configuration file:
   ```bash
   curl -L https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.yml -o docker-compose.yml
   ```

2. Pull the latest image and start the container:
   ```bash
   docker compose pull && docker compose up -d
   ```

*(Note: If you have already cloned the repository and want to manually build the production image from the local source, run: `docker compose up -d --build` instead).*

Once the container has started, access the dashboard at:
👉 **[http://localhost:3000](http://localhost:3000)**

### 2. Development Mode (Fast & Low CPU)
Mounts the source code directory directly, enabling incremental compilation and hot-code reloading. You do not need to rebuild the Docker image when editing files.
```bash
docker compose -f docker-compose.dev.yml up -d
```
* Modifying source code on the host machine instantly triggers incremental compilation in less than 0.5 seconds.
* Subsequent starts are nearly instantaneous because dependency compilation and build artifacts are cached.

### Customizing the Web Port

By default, the dashboard runs on port `3000`. If you need to run it on a different port on your host machine, you can set the `HERMIT_PORT` environment variable before running Docker Compose:

```bash
HERMIT_PORT=8080 docker compose up --build
```

This will map port `8080` on your host machine to port `3000` inside the container, making the dashboard accessible at `http://localhost:8080`.

### Running in Bridge Mode (Recommended for Host Isolation)

By default, the docker-compose configuration uses `network_mode: host` to simplify routing. However, if you want to run Hermit in an isolated Docker network (Bridge Mode) to protect the host's iptables and network interfaces, you can configure ports mapping instead:

```yaml
    ports:
      - "3000:3000"                     # Web dashboard
```

Note: If you need to access the dynamic SOCKS5/HTTP proxies (allocated inside the range `10000 - 10199`) or the dynamic DNS servers (allocated inside the range `5400 - 5500`) directly from your host machine or external network while in Bridge Mode, you will also need to map those port ranges (e.g. `"10000-10199:10000-10199"` and `"5400-5500:5400-5500/udp"`) in your docker-compose file.

---

## Production Deployment (CI/CD)

To avoid high CPU and RAM consumption on your VPS during compilation, it is recommended to build the Docker image in advance and pull it.

### 1. Automated Build via GitHub Actions
A GitHub Actions workflow is pre-configured in [.github/workflows/publish.yml](/Users/quaywin/Projects_1/hermit/.github/workflows/publish.yml). When you push code to the `main` branch:
* GitHub will automatically compile the production release.
* The image is pushed to GitHub Container Registry (GHCR) as a Public package.

### 2. Deploying on VPS
On your VPS, you only need to run the production image using a minimal `docker-compose.yml` configuration without the source code or Dockerfile. Run the following command to deploy:
```bash
docker compose pull && docker compose up -d
```

---

## Development & Testing inside Docker

When developing Hermit, it is recommended to run mix tasks and test suites directly inside the container to ensure correct behavior:

### 1. Run Precommit Checks
Before committing code, run the comprehensive precommit pipeline to format code, check for compiler warnings, and run tests:
```bash
docker compose exec hermit mix precommit
```

### 2. Run Test Suite
To run the project's tests:
```bash
docker compose exec hermit mix test
```

### 3. Fetch Dependencies
If you make changes to `mix.exs`, fetch the updated dependencies within the container:
```bash
docker compose exec hermit mix deps.get
```

---

## Why Docker?

Running real-world VPN pairs requires operating-system level root privileges to create network namespaces (`netns`), configure virtual network interfaces, and route traffic via `iptables`.
- The **`privileged: true`** setting in `docker-compose.yml` grants the container permissions to perform these system-level operations in an isolated manner.
- Running directly on your host machine risks messing up local network interfaces and requires granting global `sudo` privileges to external scripts, which is unsafe for your development environment.

---

## 🗺️ Alternatives & Similar Projects

If you are looking for other tools to manage VPNs or WireGuard tunnels, here is how **Hermit** compares to existing popular open-source alternatives:

| Project | Primary Focus | UI Type | WireGuard Management | Tailscale Integration | Network Namespace Isolation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Hermit** | Multi-tunnel orchestrator | Web Dashboard | Yes | Yes | Yes (isolated `netns`) |
| **[wireproxy](https://github.com/octeep/wireproxy)** | Userspace WireGuard proxy | CLI / Config | Yes | No | No (userspace proxy) |
| **[Gluetun](https://github.com/qdm12/gluetun)** | Docker-focused VPN client | CLI / Config | Yes | No | No (uses Docker network links) |

---

## 🤝 Contributing

Contributions are welcome! Please feel free to open issues, submit pull requests, or share ideas to improve Hermit.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
