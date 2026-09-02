#!/bin/bash
set -e

echo "========================================="
echo "   Hermit Orchestrator - Installer       "
echo "========================================="

# 0. Detect execution privilege (root / sudo)
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi
else
  SUDO=""
fi

# 1. Ensure Docker & Docker Compose are installed (Zero-Prerequisite)
if ! command -v docker >/dev/null 2>&1; then
  echo "ℹ Docker is not installed on this system. Installing official Docker Engine..."
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true
  
  if [ "$EUID" -ne 0 ] && [ -n "$USER" ]; then
    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
  fi
  echo "✓ Docker installed and started successfully."
fi

# 2. Define global configuration directory in user home
HERMIT_DIR="$HOME/.hermit"
ENV_FILE="$HERMIT_DIR/env"
COMPOSE_FILE="$HERMIT_DIR/docker-compose.yml"
IS_UPGRADE=false

mkdir -p "$HERMIT_DIR/storage"
echo "✓ Prepared config & storage directory at $HERMIT_DIR"

# 3. Check if this is an upgrade or fresh installation
if [ -f "$ENV_FILE" ]; then
  IS_UPGRADE=true
  echo "✓ Existing configuration detected. Running in UPGRADE mode..."
else
  echo "✓ Fresh installation detected. Generating secure credentials..."
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
    BASIC_AUTH_PASS=$(openssl rand -hex 6)
  else
    SECRET_KEY="hermit_secret_key_$(date +%s)_$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
    BASIC_AUTH_PASS="admin$(head -c 4 /dev/urandom | base64 | tr -dc '0-9' | head -c 4)"
  fi

  # Smart port probe for Tailscale UDP
  if ss -ulpn 2>/dev/null | grep -q ":41641\b" || lsof -i :41641 >/dev/null 2>&1; then
    TS_PORT_RANGE="41642-41700"
  else
    TS_PORT_RANGE="41641-41700"
  fi

  cat <<EOF > "$ENV_FILE"
# Hermit Environment Configurations
SECRET_KEY_BASE=$SECRET_KEY
PHX_HOST=localhost
HERMIT_PORT=3000
TAILSCALE_PORT_RANGE=$TS_PORT_RANGE
HERMIT_BASIC_AUTH_USER=admin
HERMIT_BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF
  echo "✓ Generated secure environment file at $ENV_FILE (Tailscale UDP port range: $TS_PORT_RANGE)"
fi

# 4. Setup Docker Compose configuration
if [ -f docker-compose.yml ]; then
  cp docker-compose.yml "$COMPOSE_FILE"
else
  curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.yml -o "$COMPOSE_FILE"
fi

# Create a local copy in current directory if docker-compose.yml is not here
if [ ! -f "docker-compose.yml" ]; then
  cp "$COMPOSE_FILE" ./docker-compose.yml 2>/dev/null || true
fi

# 5. Pull and Start Container
echo ""
echo "=== Pulling Latest Hermit Image ==="
if ! docker compose -f "$COMPOSE_FILE" pull; then
  echo "⚠️ Pull failed. Clearing expired GHCR credentials and retrying anonymously..."
  docker logout ghcr.io 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" pull
fi

echo ""
echo "=== Starting Hermit Container ==="
docker compose -f "$COMPOSE_FILE" up -d

# 6. Install 'hermit' CLI helper command for convenient management
CLI_SCRIPT="/usr/local/bin/hermit"
if [ -w "/usr/local/bin" ] || [ -n "$SUDO" ]; then
  $SUDO tee "$CLI_SCRIPT" >/dev/null <<'EOF'
#!/bin/bash
HERMIT_DIR="$HOME/.hermit"
COMPOSE_FILE="$HERMIT_DIR/docker-compose.yml"
ENV_FILE="$HERMIT_DIR/env"

case "$1" in
  status|ps)
    docker compose -f "$COMPOSE_FILE" ps
    ;;
  logs|log)
    shift
    docker compose -f "$COMPOSE_FILE" logs -f "$@"
    ;;
  restart)
    echo "Restarting Hermit container..."
    docker compose -f "$COMPOSE_FILE" restart
    ;;
  stop|down)
    docker compose -f "$COMPOSE_FILE" stop
    ;;
  start|up)
    docker compose -f "$COMPOSE_FILE" up -d
    ;;
  update|upgrade)
    echo "Pulling latest image and upgrading Hermit..."
    docker compose -f "$COMPOSE_FILE" pull
    docker compose -f "$COMPOSE_FILE" up -d
    echo "✓ Hermit updated successfully!"
    ;;
  env|credentials|info)
    echo "=== Hermit Configuration ($ENV_FILE) ==="
    cat "$ENV_FILE"
    ;;
  *)
    echo "Hermit Orchestrator CLI Helper"
    echo ""
    echo "Usage: hermit <command>"
    echo ""
    echo "Commands:"
    echo "  status       Show running container status"
    echo "  logs         Stream container live logs"
    echo "  restart      Restart Hermit container"
    echo "  start        Start Hermit container"
    echo "  stop         Stop Hermit container"
    echo "  update       Pull latest image and upgrade"
    echo "  env          Show credentials and environment settings"
    echo ""
    ;;
esac
EOF
  $SUDO chmod +x "$CLI_SCRIPT" 2>/dev/null || true
  echo "✓ Installed 'hermit' CLI command to $CLI_SCRIPT"
fi

# 7. Resolve Server Access URLs (Public IP, Tailscale IP, Localhost)
PORT=$(grep -E "^HERMIT_PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "3000")
USER=$(grep -E "^HERMIT_BASIC_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2 || echo "admin")
PASS=$(grep -E "^HERMIT_BASIC_AUTH_PASS=" "$ENV_FILE" | cut -d'=' -f2 || echo "")

PUBLIC_IP=$(curl -s4m 2 https://ifconfig.me 2>/dev/null || curl -s4m 2 https://api.ipify.org 2>/dev/null || echo "")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

echo ""
if [ "$IS_UPGRADE" = true ]; then
  echo "========================================="
  echo "🎉 HERMIT UPGRADED SUCCESSFULLY!"
  echo "========================================="
else
  echo "========================================="
  echo "🎉 HERMIT INSTALLED SUCCESSFULLY!"
  echo "========================================="
fi

echo "Access URLs:"
if [ -n "$PUBLIC_IP" ]; then
  echo "  👉 Public URL    : http://${PUBLIC_IP}:${PORT:-3000}"
fi
if [ -n "$TAILSCALE_IP" ]; then
  echo "  👉 Tailscale URL : http://${TAILSCALE_IP}:${PORT:-3000}"
fi
echo "  👉 Localhost     : http://localhost:${PORT:-3000}"

if [ -n "$USER" ] && [ -n "$PASS" ]; then
  echo ""
  echo "Login Credentials:"
  echo "  Username : $USER"
  echo "  Password : $PASS"
fi

echo ""
echo "Quick Management Commands:"
echo "  hermit logs      # View live logs"
echo "  hermit status    # Check container status"
echo "  hermit restart   # Restart service"
echo "  hermit update    # Upgrade to latest release"
echo "-----------------------------------------"


