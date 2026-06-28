# Hermit

Hermit is an orchestrator and manager for VPN connection pairs (combining WireGuard and Tailscale) running inside isolated network namespaces (`netns`). The application provides a real-time web dashboard to monitor bandwidth usage, manage connection states, update WireGuard configurations, and configure Tailscale authentication keys.

> ⚠️ **IMPORTANT NOTE**: This project requires elevated system privileges (`privileged: true`) and advanced networking tools such as `iptables`, `iproute2`, `wireguard-tools`, and `tailscale`. To avoid impacting your host machine's network configuration and to ensure a consistent development environment, **it is highly recommended to develop and run this project completely within Docker**.

---

## System Requirements

- **Docker** and **Docker Compose**
- There is no need to install Elixir, Erlang, or SQLite on your host machine as all runtime dependencies are packaged and configured automatically inside the container.

---

## Installation & Quick Start with Docker

To set up the database, fetch dependencies, compile assets, and launch the application, run a single command:

```bash
docker compose up --build
```

Once the container has successfully started, you can access the web interface at:
👉 **[http://localhost:3000](http://localhost:3000)**

Config files and data for your VPN tunnels will persist in the `./storage` directory on your host machine via volume mounts.

### Customizing the Web Port

By default, the dashboard runs on port `3000`. If you need to run it on a different port on your host machine, you can set the `HERMIT_PORT` environment variable before running Docker Compose:

```bash
HERMIT_PORT=8080 docker compose up --build
```

This will map port `8080` on your host machine to port `3000` inside the container, making the dashboard accessible at `http://localhost:8080`.

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
| **[Wireguard UI](https://github.com/ngoduykhanh/wireguard-ui)** | WireGuard server manager | Web UI | Yes (single server) | No | No |
| **[Netbird](https://github.com/netbirdio/netbird)** | Mesh VPN Overlay | Web & Agent | Yes (under the hood) | No (custom control plane) | No |
| **[Netmaker](https://github.com/gravitl/netmaker)** | Custom Mesh VPN | Web & Agent | Yes | No | No |
| **[Firezone](https://github.com/firezone/firezone)** | Zero Trust Access (ZTNA) | Web & Client | Yes | No | No |

### Key Differences

- **[Wireguard UI](https://github.com/ngoduykhanh/wireguard-ui)**: A web-based configuration manager for a single WireGuard server. Unlike Hermit, it does not support running multiple tunnels side-by-side or integrating them with Tailscale.
- **[Netbird](https://github.com/netbirdio/netbird)** / **[Netmaker](https://github.com/gravitl/netmaker)**: Complete mesh VPN overlay platforms that connect multiple hosts/nodes into a secure network. Hermit, on the other hand, is a local runner/orchestrator designed to pair and run WireGuard + Tailscale tunnels inside isolated network namespaces (`netns`) on a single host.
- **[Firezone](https://github.com/firezone/firezone)**: Focused on enterprise-grade secure remote access and ZTNA, managing user access to corporate resources, rather than local tunnel namespace routing and isolation.

---

## 🤝 Contributing

Contributions are welcome! Please feel free to open issues, submit pull requests, or share ideas to improve Hermit.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
