# Deploying Hermit on Fly.io (Optional / Auxiliary)

> [!NOTE]
> Hermit's primary deployment method is **Native Linux + `systemd`** via `install.sh`.
> Fly.io support is provided as an **auxiliary option** using `Dockerfile.fly` and `fly.toml.example` and does not affect native Linux installations.

This guide provides step-by-step instructions for deploying Hermit to **Fly.io** using Firecracker MicroVMs.

## Prerequisites

1. Install the Fly.io CLI (`flyctl`):
   ```bash
   # macOS / Linux
   curl -L https://fly.io/install.sh | sh
   ```
2. Log in to your Fly.io account:
   ```bash
   fly auth login
   ```

---

## Step-by-Step Deployment

### 1. Prepare `fly.toml` & Register the App

Copy the template (`fly.toml` is gitignored so your personal app settings stay out of git):

```bash
cp fly.toml.example fly.toml
```

Edit `fly.toml` and replace `app = 'your-hermit-app'` (and `primary_region = 'sin'` if desired) with your unique Fly.io app name, then initialize the app without deploying yet:

```bash
fly launch --no-deploy --copy-config --dockerfile Dockerfile.fly
```

### 2. Create a Persistent Storage Volume

Hermit stores its SQLite database (`hermit_prod.db`), WireGuard/WARP configs, Tailscale state, and generated `.secret_key_base` under `/var/lib/hermit`. Because Fly.io containers are ephemeral by default, create a persistent volume in the same region as `primary_region`:

```bash
fly volumes create hermit_data --size 1 --region sin
```

> [!NOTE]
> Make sure the volume region (e.g. `hkg`, `sin`, `nrt`, `iad`) matches `primary_region` in `fly.toml`.

### 3. Configure Secrets & Environment Variables

Set `PHX_HOST` to your Fly domain and generate a `SECRET_KEY_BASE`:

```bash
fly secrets set PHX_HOST="your-hermit-app.fly.dev"
fly secrets set SECRET_KEY_BASE="$(openssl rand -base64 48)"
```

*(Recommended)* Protect the web dashboard with HTTP Basic Authentication:

```bash
fly secrets set HERMIT_BASIC_AUTH_USER="admin" HERMIT_BASIC_AUTH_PASS="your_secure_password"
```

### 4. Deploy to Fly.io

Deploy using `Dockerfile.fly` (referenced automatically by `fly.toml`):

```bash
fly deploy
```

*(Optional)* Pass the current git tag so the dashboard displays the exact release version instead of the fallback version:

```bash
fly deploy --build-arg HERMIT_VERSION="$(git describe --tags --abbrev=0)"
```

Once deployment completes, open the web UI:

```bash
fly open
```

---

## Operation & Monitoring

- **View Live Logs**:
  ```bash
  fly logs
  ```
- **SSH into the VM**:
  ```bash
  fly ssh console
  ```
- **Check Running Network Namespaces & Swap**:
  Inside `fly ssh console`:
  ```bash
  ip netns list
  free -m
  ```
- **Upgrading**:
  Pull the latest code and re-run `fly deploy`.

---

## Architectural Notes & Limitations on Fly.io

- **Firecracker MicroVM Privileges**: Fly.io runs containers inside isolated microVMs with root privileges and `CAP_NET_ADMIN`, enabling `ip netns`, `nftables`, `tailscaled`, `3proxy`, and `wireguard-tools` without Sysbox or Docker-in-Docker. *(Kernel WireGuard depends on `ip link add ... type wireguard` support in the Fly.io VM kernel; verify tunnel startup in `fly logs` after your first deploy.)*
- **Port Isolation (`3000` vs `8080`/`8443`)**: The Phoenix Web Dashboard listens on internal port `3000` (`PORT=3000`) so it never conflicts with Hermit's internal SNI Proxy (`8080`/`8443`), while `fly-proxy` terminates public HTTPS on port `443`.
- **Unauthenticated Health Check (`/up`)**: `GET /up` bypasses Basic Auth so Fly.io HTTP checks succeed when `HERMIT_BASIC_AUTH_USER` is configured.
- **Always-On Machine (`auto_stop_machines = 'off'`)**: `fly.toml.example` disables auto-stop so active Tailscale nodes, DNS endpoints, and WireGuard tunnels stay connected 24/7.
- **512MB RAM + 512MB Swap**: `fly.toml.example` configures 512MB RAM + 512MB swap, and `bin/server` automatically activates `/swapfile` when `FLY_APP_NAME` is present if swap is not already active.
- **Tailscale DNS Endpoints**: DNS filtering and Smart DNS operate inside isolated Tailscale DNS Endpoint namespaces (`100.x.y.z`); legacy public Port 53 and `/dns-query/:token` DoH endpoints are no longer used.
- **1-Click Web Upgrade Unavailable**: Because containers do not run `/opt/hermit/releases` or `systemd`, the 1-Click Web Upgrade button in Settings (`/settings`) and the `hermit` CLI are unavailable on Fly.io — deploy updates via `fly deploy`.
- **Tailscale Direct P2P vs. DERP Relay**: Hermit allocates UDP ports in `41642–41700` per Tailscale node and configures port-preserving SNAT + policy routing (`Hermit.Vpn.Nat`). Combined with Fly.io's endpoint-independent egress NAT, Tailscale can establish **direct UDP P2P** connections via STUN hole-punching without Dedicated IPv4 or `[[services]]` UDP blocks when the client is on an easy/cone NAT network. If the client is behind strict/symmetric Hard NAT (e.g., certain 4G/5G CGNAT networks), Tailscale automatically falls back to encrypted DERP relays (you can verify via `tailscale ping <node>`).
- **Proxy Inbound Ports (`10000–29999`)**: Proxy Inbound listeners bind dynamically allocated TCP ports (`10000–29999`) unless a fixed port is configured; access them over Tailscale / Fly private networking, or assign a fixed port and expose an explicit TCP `[[services]]` block in `fly.toml` if public access is needed.
