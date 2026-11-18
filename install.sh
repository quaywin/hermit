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

# Detect interactive terminal capability
INTERACTIVE=false
if [ -t 0 ] || ([ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]); then
  INTERACTIVE=true
fi

for arg in "$@"; do
  if [ "$arg" = "-y" ] || [ "$arg" = "--yes" ] || [ "$arg" = "--non-interactive" ]; then
    INTERACTIVE=false
    break
  fi
done

if [ -n "$CI" ] || [ "$DEBIAN_FRONTEND" = "noninteractive" ]; then
  INTERACTIVE=false
fi

is_port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | grep -q ":$p\b"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i ":$p" >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpn 2>/dev/null | grep -q ":$p\b"
  else
    return 1
  fi
}

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

# 3. Check if this is an upgrade or fresh installation
if [ -f "$ENV_FILE" ]; then
  IS_UPGRADE=true
  echo "✓ Existing configuration detected at $ENV_FILE."
  
  if [ "$INTERACTIVE" = true ]; then
    printf "👉 Keep existing configuration? [Y/n]: " > /dev/tty 2>/dev/null || true
    read -r RECONF_CHOICE < /dev/tty 2>/dev/null || true
    if [ "$RECONF_CHOICE" = "n" ] || [ "$RECONF_CHOICE" = "N" ]; then
      IS_UPGRADE=false
      echo "Reconfiguring Hermit settings..."
    fi
  fi

  if [ "$IS_UPGRADE" = true ]; then
    # Ensure resource limit parameters exist in existing env file
    HOST_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    if [ "$HOST_CORES" -le 1 ]; then
      UPGRADE_CPUS="1.0"
      UPGRADE_ERL="+S 1:1"
    elif [ "$HOST_CORES" -eq 2 ]; then
      UPGRADE_CPUS="1.5"
      UPGRADE_ERL="+S 2:2"
    else
      UPGRADE_CPUS="2.0"
      UPGRADE_ERL="+S 2:2"
    fi

    if ! grep -q "^HERMIT_CPUS=" "$ENV_FILE" 2>/dev/null; then
      echo "" >> "$ENV_FILE"
      echo "# Resource limits & Erlang Schedulers (tune for your server CPU / RAM)" >> "$ENV_FILE"
      echo "HERMIT_CPUS=$UPGRADE_CPUS" >> "$ENV_FILE"
    fi
    if ! grep -q "^HERMIT_MEM_LIMIT=" "$ENV_FILE" 2>/dev/null; then
      echo "HERMIT_MEM_LIMIT=1024m" >> "$ENV_FILE"
    fi
    if ! grep -q "^ERL_FLAGS=" "$ENV_FILE" 2>/dev/null; then
      echo "ERL_FLAGS=$UPGRADE_ERL" >> "$ENV_FILE"
    fi
  fi
fi

if [ "$IS_UPGRADE" = false ]; then
  echo ""
  echo "========================================="
  echo "   Hermit Configuration Setup            "
  echo "========================================="
  echo "Configure setup parameters (press Enter to accept defaults):"
  echo ""

  # 1. Dashboard Port selection with collision detection
  SUGGESTED_PORT=3000
  if is_port_in_use 3000; then
    echo "⚠️  Port 3000 is currently in use by another service on this host."
    SUGGESTED_PORT=3008
    while is_port_in_use "$SUGGESTED_PORT"; do
      SUGGESTED_PORT=$((SUGGESTED_PORT + 1))
    done
    echo "👉 Suggested alternative port: $SUGGESTED_PORT"
  fi

  INPUT_PORT=$(ask_prompt "1. Web Dashboard Port [$SUGGESTED_PORT]: " "$SUGGESTED_PORT")
  HERMIT_PORT=$(echo "$INPUT_PORT" | tr -dc '0-9')
  [ -z "$HERMIT_PORT" ] && HERMIT_PORT="$SUGGESTED_PORT"

  # 2. Hostname / Domain
  INPUT_HOST=$(ask_prompt "2. Domain or Hostname (e.g. dns.example.com or Enter for 'localhost') [localhost]: " "localhost")
  PHX_HOST=$(echo "$INPUT_HOST" | sed -E -e 's|^https?://||' -e 's|/.*$||' -e 's|:.*$||' | tr -d '[:space:]')
  [ -z "$PHX_HOST" ] && PHX_HOST="localhost"

  # 3. Admin Username
  INPUT_USER=$(ask_prompt "3. Admin Username [admin]: " "admin")
  HERMIT_BASIC_AUTH_USER=$(echo "$INPUT_USER" | tr -d '[:space:]')
  [ -z "$HERMIT_BASIC_AUTH_USER" ] && HERMIT_BASIC_AUTH_USER="admin"

  # 4. Admin Password
  if command -v openssl >/dev/null 2>&1; then
    GEN_PASS=$(openssl rand -hex 6)
  else
    GEN_PASS="admin$(head -c 4 /dev/urandom | base64 | tr -dc '0-9' | head -c 4)"
  fi
  INPUT_PASS=$(ask_prompt "4. Admin Password [press Enter to use auto-generated: $GEN_PASS]: " "$GEN_PASS")
  HERMIT_BASIC_AUTH_PASS=$(echo "$INPUT_PASS" | tr -d '[:space:]')
  [ -z "$HERMIT_BASIC_AUTH_PASS" ] && HERMIT_BASIC_AUTH_PASS="$GEN_PASS"

  # 5. Resource Limits & CPU Allocation
  HOST_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  if [ "$HOST_CORES" -le 1 ]; then
    DEFAULT_CPUS="1.0"
    DEFAULT_ERL_FLAGS="+S 1:1"
  elif [ "$HOST_CORES" -eq 2 ]; then
    DEFAULT_CPUS="1.5"
    DEFAULT_ERL_FLAGS="+S 2:2"
  else
    DEFAULT_CPUS="2.0"
    DEFAULT_ERL_FLAGS="+S 2:2"
  fi

  INPUT_CPUS=$(ask_prompt "5. CPU Limit for Hermit (Host detected: ${HOST_CORES} cores) [$DEFAULT_CPUS]: " "$DEFAULT_CPUS")
  HERMIT_CPUS=$(echo "$INPUT_CPUS" | tr -d '[:space:]')
  [ -z "$HERMIT_CPUS" ] && HERMIT_CPUS="$DEFAULT_CPUS"

  if awk "BEGIN {exit !($HERMIT_CPUS <= 1.0)}" 2>/dev/null; then
    ERL_FLAGS="+S 1:1"
  else
    ERL_FLAGS="$DEFAULT_ERL_FLAGS"
  fi

  # 6. Secret Key Base
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
  else
    SECRET_KEY="hermit_secret_key_$(date +%s)_$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  fi

  cat <<EOF > "$ENV_FILE"
# Hermit Environment Configurations
SECRET_KEY_BASE=$SECRET_KEY
PHX_HOST=$PHX_HOST
HERMIT_PORT=$HERMIT_PORT
HERMIT_BASIC_AUTH_USER=$HERMIT_BASIC_AUTH_USER
HERMIT_BASIC_AUTH_PASS=$HERMIT_BASIC_AUTH_PASS

# Resource limits & Erlang Schedulers (tune for your server CPU / RAM)
HERMIT_CPUS=$HERMIT_CPUS
HERMIT_MEM_LIMIT=1024m
ERL_FLAGS=$ERL_FLAGS
EOF
  echo ""
  echo "✓ Generated environment configuration file at $ENV_FILE"
fi

# Ensure .env symlink exists for Docker Compose variable interpolation
ln -sf "$ENV_FILE" "$HERMIT_DIR/.env"

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
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d
    ;;
  stop|down)
    docker compose -f "$COMPOSE_FILE" stop
    ;;
  start|up)
    docker compose -f "$COMPOSE_FILE" up -d
    ;;
  update|upgrade)
    echo "Pulling latest image and upgrading Hermit..."
    if ! docker compose -f "$COMPOSE_FILE" pull; then
      echo "⚠️ Pull failed. Clearing expired GHCR credentials and retrying anonymously..."
      docker logout ghcr.io 2>/dev/null || true
      if ! docker compose -f "$COMPOSE_FILE" pull; then
        echo "❌ Error: Failed to pull latest image from ghcr.io/quaywin/hermit:latest"
        exit 1
      fi
    fi
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
HOST=$(grep -E "^PHX_HOST=" "$ENV_FILE" | cut -d'=' -f2 || echo "localhost")
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
if [ "$HOST" != "localhost" ] && [ "$HOST" != "127.0.0.1" ]; then
  echo "  👉 Domain URL    : http://${HOST}:${PORT:-3000} (or https://${HOST} if SSL reverse proxy)"
fi
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


