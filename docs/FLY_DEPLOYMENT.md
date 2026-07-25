# Deploying Hermit on Fly.io

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

### 1. Launch the Application

From the root directory of the Hermit repository, initialize your Fly app:

```bash
fly launch --no-deploy
```

This command will register your app name and generate/verify the `fly.toml` configuration.

### 2. Create a Persistent Storage Volume

Hermit uses SQLite (`hermit_prod.db`) and persistent secrets located at `/app/storage`. Because Fly.io containers are ephemeral by default, you **must create a persistent volume**:

```bash
fly volumes create hermit_data --size 1 --region sin
```

> [!NOTE]
> Make sure the region (e.g. `hkg`, `sin`, `nrt`, `iad`) matches the `primary_region` specified in your `fly.toml`.

### 3. Configure Secrets & Environment Variables

Set a strong `SECRET_KEY_BASE` and set `PHX_HOST` to your app's Fly domain:

```bash
# Set your application host domain
fly secrets set PHX_HOST="your-app-name.fly.dev"

# Generate and set a secure Secret Key Base
fly secrets set SECRET_KEY_BASE=$(openssl rand -base64 48)
```

*(Optional)* If you wish to protect the web dashboard with HTTP Basic Authentication, set the following secrets:

```bash
fly secrets set HERMIT_BASIC_AUTH_USER="admin" HERMIT_BASIC_AUTH_PASS="your_secure_password"
```

### 4. Scale Memory Resources (Recommended)

Because Hermit creates Linux network namespaces (`netns`) and orchestrates WireGuard and Tailscale tunnels concurrently, we recommend allocating at least **512MB RAM**:

```bash
fly scale memory 512
```

### 5. Deploy to Fly.io

Deploy the app to Fly.io:

```bash
fly deploy
```

Once deployment completes, open your application in the browser:

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
- **Check Running Network Namespaces**:
  Inside `fly ssh console`:
  ```bash
  ip netns list
  ```

---

## Important Architectural Notes for Fly.io

- **Firecracker MicroVM Privileges**: Fly.io runs containers inside isolated microVMs with full root privileges and kernel access (`CAP_NET_ADMIN`), enabling `ip netns`, `wireguard-tools`, `tailscale`, and `nftables` without requiring Sysbox or Docker-in-Docker setups.
- **DoH / HTTPS Endpoints**: The Phoenix HTTP server runs on port `8080` internally, while `fly-proxy` handles public TLS termination on port `443`. Secure DoH URLs (`/dns-query/:token`) work natively over Fly.io HTTPS endpoints.
