#!/bin/bash
set -e

echo "========================================="
echo "   Installing Hermit Orchestrator        "
echo "========================================="

# Define global configuration directory in user home
HERMIT_DIR="$HOME/.hermit"
ENV_FILE="$HERMIT_DIR/env"

# 1. Create storage directory in user home
mkdir -p "$HERMIT_DIR/storage"
echo "✓ Prepared config & storage directory at $HERMIT_DIR"

# 2. Automatically generate env file if it does not exist
if [ ! -f "$ENV_FILE" ]; then
  # Try openssl or fallback to a simpler generator for SECRET_KEY_BASE
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
    BASIC_AUTH_PASS=$(openssl rand -hex 6)
  else
    SECRET_KEY="fallback_secret_key_please_change_me_$(date +%s)"
    BASIC_AUTH_PASS="admin123"
  fi

  cat <<EOF > "$ENV_FILE"
# Hermit Environment Configurations
SECRET_KEY_BASE=$SECRET_KEY
PHX_HOST=localhost
HERMIT_PORT=3000
HERMIT_BASIC_AUTH_USER=admin
HERMIT_BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF
  echo "✓ Generated template environment file at $ENV_FILE"
  echo "👉 Default login credentials: admin / $BASIC_AUTH_PASS"
fi

# 3. Check for Sysbox Runtime
if docker info 2>&1 | grep -q "sysbox-runc"; then
  echo "✓ Detected Sysbox Runtime on the host system. Using secure Sysbox configuration..."
  echo "💡 Note: If container creation fails with 'namespace \"time\" does not exist' (Docker 29.5+),"
  echo "   please disable 'time-namespaces' in /etc/docker/daemon.json on your host and restart Docker."
  # Download or copy docker-compose.sysbox.yml into docker-compose.yml
  if [ -f docker-compose.sysbox.yml ]; then
    cp docker-compose.sysbox.yml docker-compose.yml
  else
    curl -sL https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.sysbox.yml -o docker-compose.yml
  fi
else
  # Sysbox not found: Warn user about privileged mode security risks
  echo ""
  echo "⚠️  IMPORTANT SECURITY WARNING:"
  echo "Sysbox Runtime was not detected on this system."
  echo "To run Hermit, we must fall back to the standard Docker configuration with 'privileged: true'."
  echo "Privileged mode grants the container full root access to the host machine's resources."
  echo ""
  echo "Recommendation: Abort this installation and install Sysbox first for maximum security."
  echo "Quick guide to install Sysbox on Ubuntu/Debian:"
  echo "  1. Download package: wget https://downloads.nestybox.com/sysbox/releases/v0.6.4/sysbox-ce_0.6.4-0.ubuntu-noble_amd64.deb"
  echo "  2. Install package:  sudo apt install ./sysbox-ce_0.6.4-0.ubuntu-noble_amd64.deb"
  echo "  Reference documentation: https://github.com/nestybox/sysbox"
  echo ""

  # Prompt user for input directly from terminal (/dev/tty)
  read -p "Do you want to proceed with 'privileged: true' mode? (y/N): " choice < /dev/tty

  if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo "➜ Proceeding with standard Docker configuration (Privileged)..."
    if [ -f docker-compose.yml ]; then
      # Make sure docker-compose.yml contains privileged if it was modified before
      # Otherwise copy the default template. We assume docker-compose.yml is already present if cloned
      echo "✓ Using existing docker-compose.yml"
    else
      curl -sL https://raw.githubusercontent.com/quaywin/hermit/main/docker-compose.yml -o docker-compose.yml
    fi
  else
    echo "❌ Installation aborted. Please install Sysbox and try again."
    exit 1
  fi
fi

# 4. Launch the application
echo "=== Starting Container ==="
docker compose up -d

echo ""
echo "=== INSTALLATION COMPLETED ==="
echo "Hermit Web Dashboard: http://localhost:$(grep HERMIT_PORT "$ENV_FILE" | cut -d'=' -f2 || echo "3000")"
echo "Login username: $(grep HERMIT_BASIC_AUTH_USER "$ENV_FILE" | cut -d'=' -f2)"
echo "Login password: $(grep HERMIT_BASIC_AUTH_PASS "$ENV_FILE" | cut -d'=' -f2)"
echo "-----------------------------------------"
