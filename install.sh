#!/bin/bash
set -euo pipefail

echo "========================================="
echo "   Hermit Orchestrator - Native Setup    "
echo "========================================="

REPO="quaywin/hermit"
TAILSCALE_VERSION="1.98.4"
INSTALL_ROOT="/opt/hermit"
CONFIG_DIR="/etc/hermit"
ENV_FILE="$CONFIG_DIR/env"
STORAGE_DIR="/var/lib/hermit"
SERVICE_FILE="/etc/systemd/system/hermit.service"
CLI_SCRIPT="/usr/local/bin/hermit"

LOCAL_TARBALL=""
INTERACTIVE=false
if [ -t 0 ] || ([ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]); then
  INTERACTIVE=true
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes|--non-interactive)
      INTERACTIVE=false
      shift
      ;;
    --tarball)
      LOCAL_TARBALL="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "${CI:-}" ] || [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ]; then
  INTERACTIVE=false
fi

# 1. Require root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this installer as root (e.g. sudo bash install.sh)."
  exit 1
fi

# 2. Detect OS & Architecture (amd64 / arm64)
if [ "$(uname -s)" != "Linux" ]; then
  echo "❌ Native installer supports Linux (Debian, Ubuntu, Raspberry Pi OS 64-bit) only."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "❌ This native installer currently supports Debian/Ubuntu/Raspberry Pi OS (apt-get)."
  exit 1
fi

RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "❌ Unsupported architecture: $RAW_ARCH (requires 64-bit amd64 or arm64, e.g. Raspberry Pi OS 64-bit)."
    exit 1
    ;;
esac
echo "✓ Detected Linux ($ARCH)"

# 3. Install runtime networking packages (without Docker)
echo "ℹ Installing runtime networking dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  libstdc++6 openssl libncurses6 ca-certificates \
  iproute2 iptables nftables wireguard-tools curl tar procps \
  openresolv ethtool microsocks tinyproxy iputils-ping >/dev/null

# Stop default host tinyproxy service so it does not occupy port 8888 on host
if systemctl list-unit-files tinyproxy.service >/dev/null 2>&1; then
  systemctl disable --now tinyproxy.service >/dev/null 2>&1 || true
fi

# Stop legacy Docker container if running to prevent port conflicts (3000, 8080, 8443)
if command -v docker >/dev/null 2>&1; then
  LEGACY_CONTAINERS=$(docker ps -q --filter "name=hermit" 2>/dev/null || true)
  if [ -n "$LEGACY_CONTAINERS" ]; then
    echo "ℹ Stopping legacy Hermit Docker container to avoid port conflicts..."
    docker stop $LEGACY_CONTAINERS >/dev/null 2>&1 || true
    echo "✓ Legacy Docker container stopped."
  fi
fi

# Ensure tailscale & tailscaled binaries exist (without disturbing existing host tailscaled)
if ! command -v tailscaled >/dev/null 2>&1 || ! command -v tailscale >/dev/null 2>&1; then
  echo "ℹ Installing Tailscale ${TAILSCALE_VERSION} binaries..."
  TMP_TS=$(mktemp -d)
  TS_ARCHIVE="$TMP_TS/tailscale.tgz"
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${ARCH}.tgz" -o "$TS_ARCHIVE"
  tar -xzf "$TS_ARCHIVE" -C "$TMP_TS"
  install -m 0755 "$TMP_TS/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscale" /usr/local/bin/tailscale
  install -m 0755 "$TMP_TS/tailscale_${TAILSCALE_VERSION}_${ARCH}/tailscaled" /usr/local/bin/tailscaled
  rm -rf "$TMP_TS"
fi
echo "✓ Runtime dependencies ready"

# 4. Prepare directories & environment configuration
mkdir -p "$INSTALL_ROOT/releases" "$CONFIG_DIR" "$STORAGE_DIR"

# Migrate legacy SQLite database if upgrading from old Docker installation
LEGACY_STORAGE=""
for candidate in "$HOME/.hermit/storage" "/root/.hermit/storage" /home/*/.hermit/storage; do
  if [ -f "$candidate/hermit_prod.db" ]; then
    LEGACY_STORAGE="$candidate"
    break
  fi
done

if [ -n "$LEGACY_STORAGE" ] && [ ! -f "$STORAGE_DIR/hermit_prod.db" ]; then
  echo "ℹ Detected legacy Docker database at $LEGACY_STORAGE. Migrating to $STORAGE_DIR..."
  cp -a "$LEGACY_STORAGE/." "$STORAGE_DIR/" 2>/dev/null || true
  chmod -R 0700 "$STORAGE_DIR"
  echo "✓ Successfully migrated database and keys to $STORAGE_DIR"
fi

ask_prompt() {
  local prompt="$1"
  local default_val="$2"
  local result=""

  if [ "$INTERACTIVE" = true ]; then
    if [ -t 0 ]; then
      read -r -p "$prompt" result || true
    elif [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf "%s" "$prompt" > /dev/tty 2>/dev/null || true
      read -r result < /dev/tty 2>/dev/null || true
    fi
  fi

  if [ -z "$result" ]; then
    echo "$default_val"
  else
    echo "$result"
  fi
}

IS_UPGRADE=false
if [ -f "$ENV_FILE" ]; then
  IS_UPGRADE=true
  echo "✓ Existing configuration detected at $ENV_FILE (preserving settings)."
else
  DEFAULT_PORT="3000"
  DEFAULT_HOST="localhost"
  DEFAULT_USER="admin"
  DEFAULT_PASS=$(openssl rand -hex 6)
  SECRET_KEY=""
  USE_LEGACY=false

  LEGACY_ENV=""
  for candidate in "$HOME/.hermit/env" "/root/.hermit/env" /home/*/.hermit/env; do
    if [ -f "$candidate" ]; then
      LEGACY_ENV="$candidate"
      break
    fi
  done

  if [ -n "$LEGACY_ENV" ]; then
    LEGACY_PORT=$(grep -E "^HERMIT_PORT=" "$LEGACY_ENV" | cut -d'=' -f2 || echo "")
    [ -n "$LEGACY_PORT" ] && DEFAULT_PORT="$LEGACY_PORT"
    LEGACY_HOST=$(grep -E "^PHX_HOST=" "$LEGACY_ENV" | cut -d'=' -f2 || echo "")
    [ -n "$LEGACY_HOST" ] && DEFAULT_HOST="$LEGACY_HOST"
    LEGACY_USER=$(grep -E "^HERMIT_BASIC_AUTH_USER=" "$LEGACY_ENV" | cut -d'=' -f2 || echo "")
    [ -n "$LEGACY_USER" ] && DEFAULT_USER="$LEGACY_USER"
    LEGACY_PASS=$(grep -E "^HERMIT_BASIC_AUTH_PASS=" "$LEGACY_ENV" | cut -d'=' -f2 || echo "")
    [ -n "$LEGACY_PASS" ] && DEFAULT_PASS="$LEGACY_PASS"
    LEGACY_SECRET=$(grep -E "^SECRET_KEY_BASE=" "$LEGACY_ENV" | cut -d'=' -f2 || echo "")
    [ -n "$LEGACY_SECRET" ] && SECRET_KEY="$LEGACY_SECRET"

    echo ""
    echo "ℹ Detected legacy Docker configuration at $LEGACY_ENV:"
    echo "  • Port     : $DEFAULT_PORT"
    echo "  • Host     : $DEFAULT_HOST"
    echo "  • Username : $DEFAULT_USER"
    echo "  • Password : $DEFAULT_PASS"
    echo ""
    KEEP_LEGACY=$(ask_prompt "Do you want to reuse this configuration? [Y/n]: " "Y")
    case "$KEEP_LEGACY" in
      [nN]|[nN][oO])
        USE_LEGACY=false
        ;;
      *)
        USE_LEGACY=true
        ;;
    esac
  fi

  if [ "$USE_LEGACY" = true ]; then
    HERMIT_PORT="$DEFAULT_PORT"
    PHX_HOST="$DEFAULT_HOST"
    HERMIT_BASIC_AUTH_USER="$DEFAULT_USER"
    HERMIT_BASIC_AUTH_PASS="$DEFAULT_PASS"
    echo "✓ Reusing legacy Docker configuration."
  else
    echo ""
    echo "=== Hermit Configuration Setup ==="
    INPUT_PORT=$(ask_prompt "1. Web Dashboard Port [$DEFAULT_PORT]: " "$DEFAULT_PORT")
    HERMIT_PORT=$(echo "$INPUT_PORT" | tr -dc '0-9')
    [ -z "$HERMIT_PORT" ] && HERMIT_PORT="$DEFAULT_PORT"

    INPUT_HOST=$(ask_prompt "2. Hostname or Domain [$DEFAULT_HOST]: " "$DEFAULT_HOST")
    PHX_HOST=$(echo "$INPUT_HOST" | sed -E -e 's|^https?://||' -e 's|/.*$||' -e 's|:.*$||' | tr -d '[:space:]')
    [ -z "$PHX_HOST" ] && PHX_HOST="$DEFAULT_HOST"

    INPUT_USER=$(ask_prompt "3. Admin Username [$DEFAULT_USER]: " "$DEFAULT_USER")
    HERMIT_BASIC_AUTH_USER=$(echo "$INPUT_USER" | tr -d '[:space:]')
    [ -z "$HERMIT_BASIC_AUTH_USER" ] && HERMIT_BASIC_AUTH_USER="$DEFAULT_USER"

    INPUT_PASS=$(ask_prompt "4. Admin Password [Enter for default: $DEFAULT_PASS]: " "$DEFAULT_PASS")
    HERMIT_BASIC_AUTH_PASS=$(echo "$INPUT_PASS" | tr -d '[:space:]')
    [ -z "$HERMIT_BASIC_AUTH_PASS" ] && HERMIT_BASIC_AUTH_PASS="$DEFAULT_PASS"
  fi

  HOST_CORES=$(nproc 2>/dev/null || echo 1)
  if [ "$HOST_CORES" -le 1 ]; then
    DEFAULT_ERL_AFLAGS="+S 1:1"
  else
    DEFAULT_ERL_AFLAGS="+S 2:2"
  fi

  [ -z "$SECRET_KEY" ] && SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')

  cat <<EOF > "$ENV_FILE"
# Hermit Native Environment Configuration
MIX_ENV=prod
PHX_SERVER=true
PORT=$HERMIT_PORT
HERMIT_PORT=$HERMIT_PORT
PHX_HOST=$PHX_HOST
STORAGE_BASE_PATH=$STORAGE_DIR
SECRET_KEY_BASE=$SECRET_KEY
HERMIT_BASIC_AUTH_USER=$HERMIT_BASIC_AUTH_USER
HERMIT_BASIC_AUTH_PASS=$HERMIT_BASIC_AUTH_PASS

# Memory & scheduler tuning (fixed BEAM flags live in rel/vm.args.eex)
ERL_AFLAGS=$DEFAULT_ERL_AFLAGS
ERL_CRASH_DUMP_SECONDS=0
GOMEMLIMIT=32MiB
GOGC=50
POOL_SIZE=2
EOF
  chmod 0600 "$ENV_FILE"
  echo "✓ Generated $ENV_FILE"
fi

# 5. Download & extract release tarball atomically
RELEASE_ID=$(date +%Y%m%d%H%M%S)
RELEASE_DIR="$INSTALL_ROOT/releases/$RELEASE_ID"
mkdir -p "$RELEASE_DIR"

if [ -n "$LOCAL_TARBALL" ]; then
  echo "ℹ Extracting local release archive: $LOCAL_TARBALL"
  tar -xzf "$LOCAL_TARBALL" -C "$RELEASE_DIR"
else
  TARBALL_URL="https://github.com/${REPO}/releases/latest/download/hermit-linux-${ARCH}.tar.gz"
  echo "ℹ Downloading Hermit release ($ARCH) from $TARBALL_URL..."
  TMP_TAR=$(mktemp)
  if ! curl -fsSL "$TARBALL_URL" -o "$TMP_TAR"; then
    rm -f "$TMP_TAR"
    rm -rf "$RELEASE_DIR"
    echo "❌ Failed to download $TARBALL_URL."
    echo "   Tip: Build a release tarball with ./scripts/build-native-release.sh and install using:"
    echo "   sudo bash install.sh --tarball /path/to/hermit-linux-${ARCH}.tar.gz"
    exit 1
  fi
  tar -xzf "$TMP_TAR" -C "$RELEASE_DIR"
  rm -f "$TMP_TAR"
fi

chmod +x "$RELEASE_DIR/bin/server" "$RELEASE_DIR/bin/hermit" 2>/dev/null || true
ln -sfn "$RELEASE_DIR" "$INSTALL_ROOT/current"

# Keep only the 2 most recent releases to save disk space
ls -1dt "$INSTALL_ROOT/releases/"* 2>/dev/null | tail -n +3 | xargs -r rm -rf

# 6. Install systemd service
cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=Hermit VPN & Smart DNS Orchestrator
Documentation=https://github.com/quaywin/hermit
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hermit/current
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=/etc/hermit/env
ExecStart=/opt/hermit/current/bin/server
Restart=always
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermit

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermit.service >/dev/null 2>&1
systemctl restart hermit.service
echo "✓ Systemd service hermit.service started"

# 7. Save installer locally for safe upgrades and install 'hermit' CLI helper
if [ -f "$0" ] && [ "$(basename "$0")" != "bash" ] && [ "$(basename "$0")" != "sh" ]; then
  install -m 0755 "$0" "$INSTALL_ROOT/install.sh" 2>/dev/null || true
else
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/install.sh" -o "$INSTALL_ROOT/install.sh" 2>/dev/null || true
  chmod 0755 "$INSTALL_ROOT/install.sh" 2>/dev/null || true
fi

cat <<'EOF' > "$CLI_SCRIPT"
#!/bin/bash
set -euo pipefail

case "${1:-}" in
  status)
    systemctl status hermit.service --no-pager
    ;;
  logs|log)
    shift
    journalctl -u hermit.service -f "$@"
    ;;
  restart)
    sudo systemctl restart hermit.service
    echo "✓ Hermit restarted."
    ;;
  start)
    sudo systemctl start hermit.service
    echo "✓ Hermit started."
    ;;
  stop)
    sudo systemctl stop hermit.service
    echo "✓ Hermit stopped."
    ;;
  update|upgrade)
    if [ -x /opt/hermit/install.sh ]; then
      sudo /opt/hermit/install.sh --yes "$@"
    else
      echo "Installer not found at /opt/hermit/install.sh. Running latest installer from GitHub..."
      curl -fsSL "https://raw.githubusercontent.com/quaywin/hermit/main/install.sh" | sudo bash -s -- --yes "$@"
    fi
    ;;
  env|info)
    sudo cat /etc/hermit/env
    ;;
  uninstall)
    echo "Stopping Hermit and cleaning up network resources..."
    sudo systemctl disable --now hermit.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/hermit.service
    sudo systemctl daemon-reload
    sudo nft delete table inet hermit_host 2>/dev/null || true
    for ns in /var/run/netns/hermit_*; do
      [ -e "$ns" ] && sudo ip netns del "$(basename "$ns")" 2>/dev/null || true
    done
    sudo rm -rf /opt/hermit /usr/local/bin/hermit
    echo "✓ Hermit uninstalled. Config (/etc/hermit) and data (/var/lib/hermit) were preserved."
    ;;
  *)
    echo "Hermit Native CLI"
    echo "Usage: hermit <status|logs|start|stop|restart|update|env|uninstall>"
    ;;
esac
EOF
chmod +x "$CLI_SCRIPT"
echo "✓ Installed CLI helper at $CLI_SCRIPT"

PORT=$(grep -E "^PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "3000")
USER=$(grep -E "^HERMIT_BASIC_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2 || echo "admin")
PASS=$(grep -E "^HERMIT_BASIC_AUTH_PASS=" "$ENV_FILE" | cut -d'=' -f2 || echo "")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

echo ""
echo "========================================="
if [ "$IS_UPGRADE" = true ]; then
  echo "🎉 HERMIT NATIVE UPGRADED SUCCESSFULLY!"
else
  echo "🎉 HERMIT NATIVE INSTALLED SUCCESSFULLY!"
fi
echo "========================================="
echo "  Local URL     : http://localhost:${PORT}"
[ -n "$TAILSCALE_IP" ] && echo "  Tailscale URL : http://${TAILSCALE_IP}:${PORT}"
[ -n "$PASS" ] && echo "  Credentials   : ${USER} / ${PASS}"
echo ""
echo "Commands: hermit status | hermit logs | hermit restart | hermit update | hermit uninstall"
