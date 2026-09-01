#!/bin/bash
set -e

echo "========================================="
echo "   Hermit Orchestrator - Installer       "
echo "========================================="

# 1. Define global configuration directory in user home
HERMIT_DIR="$HOME/.hermit"
ENV_FILE="$HERMIT_DIR/env"
COMPOSE_FILE="$HERMIT_DIR/docker-compose.yml"
IS_UPGRADE=false

mkdir -p "$HERMIT_DIR/storage"
echo "✓ Prepared config & storage directory at $HERMIT_DIR"

# 2. Check if this is an upgrade or fresh installation
if [ -f "$ENV_FILE" ]; then
  IS_UPGRADE=true
  echo "✓ Existing configuration detected. Running in UPGRADE mode..."
else
  echo "✓ Fresh installation detected. Generating credentials..."
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
    BASIC_AUTH_PASS=$(openssl rand -hex 6)
  else
    SECRET_KEY="hermit_secret_key_$(date +%s)_$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
    BASIC_AUTH_PASS="admin$(head -c 4 /dev/urandom | base64 | tr -dc '0-9' | head -c 4)"
  fi

  cat <<EOF > "$ENV_FILE"
# Hermit Environment Configurations
SECRET_KEY_BASE=$SECRET_KEY
PHX_HOST=localhost
HERMIT_PORT=3000
HERMIT_BASIC_AUTH_USER=admin
HERMIT_BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF
  echo "✓ Generated secure environment file at $ENV_FILE"
fi

# 3. Setup Docker Compose configuration
if docker info 2>&1 | grep -q "sysbox-runc"; then
  echo "✓ Detected Sysbox Runtime. Using secure Sysbox configuration..."
  if [ -f docker-compose.sysbox.yml ]; then
    cp docker-compose.sysbox.yml "$COMPOSE_FILE"
  else
    curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.sysbox.yml -o "$COMPOSE_FILE"
  fi
else
  echo "ℹ Using standard Docker configuration (privileged mode)..."
  if [ -f docker-compose.yml ]; then
    cp docker-compose.yml "$COMPOSE_FILE"
  else
    curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.yml -o "$COMPOSE_FILE"
  fi
fi

# Create a symlink or local copy in current directory if docker-compose.yml is not here
if [ ! -f "docker-compose.yml" ]; then
  cp "$COMPOSE_FILE" ./docker-compose.yml 2>/dev/null || true
fi

# 4. Pull and Start Container
echo ""
echo "=== Pulling Latest Image ==="
if ! docker compose -f "$COMPOSE_FILE" pull; then
  echo "⚠️ Pull failed. Clearing expired GHCR credentials and retrying anonymously..."
  docker logout ghcr.io 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" pull
fi

echo ""
echo "=== Starting Hermit Container ==="
docker compose -f "$COMPOSE_FILE" up -d

# 5. Display Completion Summary
PORT=$(grep -E "^HERMIT_PORT=" "$ENV_FILE" | cut -d'=' -f2 || echo "3000")
USER=$(grep -E "^HERMIT_BASIC_AUTH_USER=" "$ENV_FILE" | cut -d'=' -f2 || echo "admin")
PASS=$(grep -E "^HERMIT_BASIC_AUTH_PASS=" "$ENV_FILE" | cut -d'=' -f2 || echo "")

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

echo "Web Dashboard : http://localhost:${PORT:-3000}"
if [ -n "$USER" ] && [ -n "$PASS" ]; then
  echo "Username      : $USER"
  echo "Password      : $PASS"
fi
echo "Config Dir    : $HERMIT_DIR"
echo "Storage Dir   : $HERMIT_DIR/storage"
echo ""
echo "💡 To upgrade in the future, simply run:"
echo "   curl -fsSL https://raw.githubusercontent.com/quaywin/hermit/main/install.sh | bash"
echo "-----------------------------------------"

