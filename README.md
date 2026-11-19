<h1 align="center">
  <img src="priv/static/images/logo.png" alt="Hermit Logo" width="40" height="40" /> Hermit
</h1>

<p align="center">
  <strong>The Self-Hosted All-in-One Network & Privacy Gateway</strong><br>
  Tailscale Mesh Ad-Blocking DNS + Multi-Tunnel VPN Mesh Orchestrator.
</p>

<p align="center">
  <a href="https://github.com/quaywin/hermit/releases"><img src="https://img.shields.io/github/v/release/quaywin/hermit?color=emerald" alt="Release"></a>
  <a href="https://github.com/quaywin/hermit/blob/main/LICENSE"><img src="https://img.shields.io/github/license/quaywin/hermit.svg" alt="License"></a>
  <a href="https://elixir-lang.org"><img src="https://img.shields.io/badge/language-Elixir%201.19-purple.svg" alt="Language"></a>
  <a href="https://phoenixframework.org"><img src="https://img.shields.io/badge/framework-Phoenix%20LiveView-orange.svg" alt="Framework"></a>
  <a href="https://github.com/quaywin/hermit/releases/latest"><img src="https://img.shields.io/badge/platform-Linux%20native%20(amd64%20%7C%20arm64)-blue.svg" alt="Native Linux"></a>
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Hermit Dashboard Preview" width="100%" />
</p>

---

## ⚡ What is Hermit?

**Hermit** turns any Linux machine or cheap VPS (Debian, Ubuntu, Raspberry Pi OS 64-bit) into a private, high-performance security hub for all your personal devices:

1. 🛡️ **Tailscale Mesh DNS & Ad-Blocking Control Plane**: Filter ads, malware, and trackers across your private Tailnet with built-in blocklists (AdGuard, GoodbyeAds, Adult filters) and custom domain routing rules running inside isolated network namespaces.
2. 🌐 **Multi-Tunnel VPN Orchestrator**: Pair incoming connections (**Tailscale nodes**, **SOCKS5/HTTP proxies**) with outgoing VPN gateways (**WireGuard**, **Host Direct**) running in completely **isolated Linux network namespaces (`netns`)**. Zero port conflicts, zero route leaks, and zero impact on your host network.
3. 🔀 **Domain-Based Split Tunneling (Smart DNS & SNI Proxy)**: Route specific geo-restricted domains (`netflix.com`, `*.openai.com`, etc.) through designated VPN tunnels automatically without needing an Exit Node or installing VPN clients on your device. Zero SSL certificate errors, zero battery drain.
4. 📊 **Real-Time Web Dashboard**: Built with Phoenix LiveView. Monitor 24-hour DNS telemetry, query volume, blocked threats, throughput, ping latencies, and device status with real-time updates and zero polling overhead.

---

## 🚀 Quick Start (Remote 1-Line Installer)

Hermit runs as a high-performance, native Linux systemd service on **x86_64 (`amd64`)** and **ARM64 (`arm64`)** (Raspberry Pi 64-bit, AWS Graviton, Oracle Cloud ARM, Debian/Ubuntu VPS).

To install or upgrade Hermit on any Linux server remotely:

```bash
curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/install.sh | sudo bash
```

### What the installer handles automatically:
* Installs minimal Linux networking tools (`nftables`, `wireguard-tools`, `ethtool`, etc.) without installing host proxy services.
* Isolates `tailscale`, `tailscaled`, and `3proxy` binaries under `/opt/hermit/bin/` so your host `/usr/local/bin` and system configuration remain clean.
* Downloads and verifies the precompiled native release tarball (`SHA256SUMS`) for your CPU architecture.
* Automatically migrates legacy database records and settings if upgrading from Docker (`~/.hermit/storage` $\rightarrow$ `/var/lib/hermit`).
* Sets up and starts `hermit.service` via `systemd` under `/opt/hermit`.
* Creates the global `hermit` CLI helper.

Once completed, the terminal outputs your access details:
* **Web Dashboard**: `http://<your-server-ip>:3000` (or `http://localhost:3000`)
* **Default Username**: `admin`
* **Password**: *Printed in your terminal (stored securely in `/etc/hermit/env`)*

---

### Non-Interactive / Automation Flag (`-y`)

For automated server deployments (Ansible, Cloud-init, CI/CD), pass `-y` to skip all prompts and use defaults/existing settings:

```bash
curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/install.sh | sudo bash -s -- -y
```

---

## 🎯 Common Use Cases & How It Works

### Use Case 1: Tailnet-Wide Ad-Blocking DNS

Stop ads, trackers, and malicious domains across your entire Tailscale network without configuring individual devices or dealing with SSL certificates:

1. Open Hermit Web Dashboard $\rightarrow$ Click **Endpoints** in the sidebar.
2. An Endpoint is pre-created with default ad-blocking filters enabled. Assign it a Tailscale Auth Key.
3. Hermit boots an isolated Tailscale node (e.g. `100.x.y.z`) running Smart Ad-Blocking DNS.
4. In your [Tailscale Admin Console → DNS](https://login.tailscale.com/admin/dns):
   * Under **Nameservers**, add Hermit's Tailscale IP as a Global Nameserver.
   * Enable **Override local DNS** if you want all devices in your tailnet protected automatically.
5. Watch blocked queries appear in real-time on your **Dashboard**!

---

### Use Case 2: Multi-Tunnel VPN Mesh (Tailscale + WireGuard)

Route your traffic from anywhere in the world through a trusted WireGuard VPN provider (Mullvad, Proton, NordVPN, IVPN, etc.) using Tailscale:

```mermaid
flowchart LR
    Client["Your Devices (Phone / Laptop)"] -->|Tailscale Mesh| Inbound["Tailscale Inbound Node"]
    subgraph NetNS ["Isolated Network Namespace"]
        Inbound -->|Internal Forwarding| Outbound["WireGuard Outbound Profile"]
    end
    Outbound -->|Encrypted WireGuard| Internet["Target Country Internet"]
```

1. **Add Inbound Profile** (`/inbounds`):
   * Select **Tailscale** $\rightarrow$ Enter your Tailscale Auth Key (`tskey-auth-...` or OAuth `tskey-client-...`).
2. **Add Outbound Profile** (`/outbounds`):
   * Paste your WireGuard configuration (`.conf` file or private key, server endpoint, address).
3. **Deploy Tunnel** (`/`):
   * Pair your Inbound and Outbound profiles $\rightarrow$ Click **Deploy Tunnel**.
   * Hermit will spawn an isolated network namespace, boot the Tailscale node, establish the WireGuard connection, and configure routing rules.
4. On your phone or laptop, simply open the Tailscale app and select `hermit-node-...` as your **Exit Node**!

---

### Use Case 3: Domain-Based Split Tunneling (Smart DNS & SNI Proxy)

Stream geo-restricted media (e.g. Netflix US, BBC iPlayer) or unblock services (e.g. OpenAI) on your Smart TV, phone, or laptop without routing all your computer's traffic through a full VPN exit node:

```mermaid
flowchart LR
    Client["Client (Phone / TV / PC)\n(Only sets Hermit DNS)"] -->|1. Query netflix.com| DNS["Hermit Smart DNS\n(Tailscale Mesh Node)"]
    DNS -->|2. Returns Hermit IP| Client
    Client -->|3. HTTPS port 443\n(TLS ClientHello)| SNI["Transparent SNI Proxy\n(Ports 443 / 80)"]
    subgraph Tunnel ["Isolated Tunnel Netns"]
        SNI -->|4. SOCKS5 Relay| SOCKS["microsocks Daemon"]
        SOCKS -->|5. WireGuard Outbound| Target["US WireGuard Gateway\n(netflix.com)"]
    end
    Client -.->|Normal traffic (e.g. google.com)\nDirect local ISP connection| Internet["Direct Internet"]
```

#### Why Smart DNS is Faster & Better than a Full Exit Node:
* ⚡ **Traffic Offloading (Max Speed)**: 98% of your everyday browsing (YouTube, banking, gaming, local sites) stays on your direct ISP connection with 1 Gbps speed and 2–5ms latency. Only specified domains are routed through VPN tunnels.
* 🚀 **Low Latency Handshake**: TLS ClientHello connections to Hermit occur over fast Tailscale P2P / LAN (1–5ms RTT), avoiding round-trip penalties across the globe on initial connection.
* 🛡️ **Bypasses ISP IP & DPI Blocks**: Because DNS returns Hermit's IP, your device never attempts to connect directly to the target server's IP. All web content (HTML, media, video streams) is fetched through the WireGuard tunnel at the destination country and proxied back to you.
* 🚫 **No CAPTCHAs**: Normal browsing retains your clean residential ISP IP, preventing annoying Cloudflare/Google robot checks.
* 🔋 **Zero Battery Drain & Zero Client Apps**: Smart TVs, Apple TVs, gaming consoles, and mobile devices only need Hermit DNS configured (or Tailscale connected with Exit Node **OFF**).

#### How to Configure:
1. Open your tunnel's detail page on Hermit.
2. In the unified **Routing Targets (Split-Tunnel)** box, enter your targets:
   * **Domains** (e.g. `*.netflix.com, *.openai.com`): Automatically intercepted via Smart DNS & SNI Proxy.
   * **IP Subnets** (e.g. `192.168.1.0/24, 10.0.0.0/8`): Automatically advertised via Tailscale Subnet Router.
3. Set Hermit's Tailscale DNS Endpoint IP as your Tailscale Nameserver (MagicDNS) or device DNS.
4. Enjoy transparent domain-level split tunneling with **zero client VPN apps** and **zero SSL certificate errors**!

> [!TIP]
> **Common Domain Sets for Popular Services (Include Asset & CDN Domains)**:
> Major streaming and AI platforms serve static files, images, and video feeds from separate CDN domains. For full coverage without broken styles or missing assets:
> * **BBC (UK)**: `*.bbc.co.uk, *.bbci.co.uk, *.bbc.com` *(covers main portal, iPlayer, iChef image CDN, and static file CDN)*.
> * **OpenAI / ChatGPT**: `*.openai.com, *.chatgpt.com, *.oaistatic.com, *.oaiusercontent.com`.
> * **Netflix**: `*.netflix.com, *.nflxvideo.net, *.nflximg.net, *.nflxext.com`.
> 
> Changes apply **instantly (0s delay)** without restarting tunnels — Hermit automatically clears its internal DNS cache and refreshes routing rules in real-time.

---

## 🛠️ Everyday Management via `hermit` CLI

The installer creates a lightweight `hermit` CLI helper on your server:

```bash
hermit status    # View service status, uptime, and memory usage
hermit logs      # Follow live systemd journal logs
hermit restart   # Restart Hermit service
hermit update    # Download latest release and seamlessly upgrade
hermit env       # View web credentials and environment variables (/etc/hermit/env)
hermit stop      # Stop Hermit service
hermit start     # Start Hermit service
hermit uninstall # Safely uninstall Hermit service and binaries
```

---

## 🔄 Frictionless Upgrades

Hermit preserves all your database records, tokens, and active tunnel states across upgrades:

* **1-Click Web Upgrade (Zero Terminal)**:
  Navigate to **Settings** (`/settings`) on the web dashboard. When an update is released, click **[Upgrade]** — Hermit downloads the new binary and restarts seamlessly in ~5 seconds.
* **Terminal Upgrade**:
  ```bash
  hermit update
  # or re-run the 1-line installer:
  curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/install.sh | sudo bash
  ```

---

## ⚙️ Configuration & Reference

<details>
<summary><strong>Port Reference & Firewall Guide</strong></summary>

When running Hermit natively on Linux:

| Port / Protocol | Service | Description |
| :--- | :--- | :--- |
| **`3000/tcp`** | Web Dashboard | Phoenix LiveView Web UI (`/`). Customizable via `HERMIT_PORT`. |
| **`443/tcp, 80/tcp`** | Smart DNS SNI Proxy | Transparent SNI proxy for domain-based split tunneling (Zero-crypto raw TCP streaming). |
| **`Dynamic UDP`** | Tailscale Inbounds | **Zero-config**: Automatically allocates free ephemeral ports (`41642-41700`) for direct P2P connections. |

> [!TIP]
> **Zero Host DNS Conflicts**:
> Hermit does **not** bind to host port 53 by default. Smart DNS resolvers run inside isolated Tailscale node namespaces, completely eliminating conflicts with `systemd-resolved` or existing host DNS servers. Hermit will also **never conflict** with your host's Tailscale daemon (`41641/udp`) or interrupt your SSH sessions.
</details>

<details>
<summary><strong>Tailscale ACL & OAuth Client Setup (`tag:hermit`)</strong></summary>

When registering Tailscale Inbound nodes or DNS Endpoints with OAuth client keys (`tskey-client-...`), Tailscale requires devices to declare an ACL tag.

1. **Tag Declaration (`tag:hermit`)**:
   Add this to your [Tailscale Admin Console → Access Controls (ACL)](https://login.tailscale.com/admin/acls):
   ```json
   {
     "tagOwners": {
       "tag:hermit": ["autogroup:admin"]
     }
   }
   ```

2. **Auto-Approving Exit Node Routes (Recommended)**:
   To let Hermit tunnels act as Exit Nodes automatically without manual approval:
   ```json
   {
     "autoApprovers": {
       "exitNode": ["tag:hermit"],
       "routes": {
         "0.0.0.0/0": ["tag:hermit"],
         "::/0": ["tag:hermit"]
       }
     }
   }
   ```
</details>

<details>
<summary><strong>High-Throughput Performance Tuning (UDP GRO)</strong></summary>

Hermit automatically enables UDP GRO offloading on virtual interfaces inside network namespaces.

For maximum throughput (especially on 1Gbps+ connections), enable UDP GRO on your host's physical network interface once:
```bash
sudo sh -c 'ethtool -K $(ip -o route get 8.8.8.8 | cut -f 5 -d " ") rx-udp-gro-forwarding on rx-gro-list off'
```
</details>

<details>
<summary><strong>Local Development Mode</strong></summary>

To develop or modify Hermit locally with live code reload:

```bash
git clone https://github.com/quaywin/hermit.git
cd hermit
mix setup
mix phx.server
```
The Phoenix server will reload code changes incrementally in `< 0.5s`.
</details>

---

## 💡 Why Network Namespaces (`netns`) & Native Systemd?

Running multiple VPN tunnels simultaneously on a single Linux machine normally creates severe routing table conflicts (e.g., conflicting `default` gateways and overlapping subnet routes).

Hermit solves this natively by assigning every connection pair its own **Linux Network Namespace (`netns`)** and **`nftables`** rules:
* Each tunnel has its own independent virtual network interfaces and routing table.
* The native systemd service (`hermit.service`) runs directly with standard Linux network capabilities, eliminating Docker virtualization overhead.
* Your host operating system's routing tables and interfaces remain 100% clean and unaffected.

---

## 📜 License & Credits

Hermit is open-source software licensed under the [MIT License](LICENSE).

Built with appreciation for:
* **[WireGuard](https://www.wireguard.com/)** - Modern, secure, and fast VPN protocol.
* **[Tailscale](https://tailscale.com/)** - Effortless private overlay mesh networking.
* **[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)** & **[GoodbyeAds](https://github.com/jerryn70/GoodbyeAds)** - Comprehensive ad-blocking filter lists.
* **[Elixir](https://elixir-lang.org/)** & **[Phoenix LiveView](https://phoenixframework.org/)** - For enabling real-time reactivity with minimal footprint.
