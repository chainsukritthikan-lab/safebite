#!/usr/bin/env bash
#
# One-time bootstrap for a fresh Oracle Cloud (or any Ubuntu) VM.
# Installs Docker, opens the Bedrock port in the VM's own firewall, adds swap,
# and schedules nightly backups.
#
# Usage:  ./setup.sh
#
# Safe to re-run — every step checks before it acts.

set -euo pipefail

PORT=19132
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
  warn "Running as root. Expected a normal user with sudo; continuing anyway."
  SUDO=""
else
  SUDO="sudo"
fi

# --------------------------------------------------------------- sanity ------
say "Checking the machine"

ARCH="$(uname -m)"
echo "    architecture : $ARCH"
echo "    memory       : $(free -h | awk '/^Mem:/ {print $2}')"
echo "    cores        : $(nproc)"

if [[ "$ARCH" == "aarch64" ]]; then
  PAGESIZE="$(getconf PAGESIZE)"
  echo "    page size    : $PAGESIZE"
  if [[ "$PAGESIZE" != "4096" ]]; then
    warn "This ARM kernel uses ${PAGESIZE}-byte pages, but box64 needs 4096."
    warn "The Bedrock server will NOT start here. This normally means the VM"
    warn "is running Oracle Linux or AlmaLinux instead of Ubuntu."
    warn "Rebuild the VM with Ubuntu, or use docker-compose.geyser.yml instead."
  fi
fi

# --------------------------------------------------------------- docker ------
if command -v docker >/dev/null 2>&1; then
  say "Docker already installed — skipping"
else
  say "Installing Docker"
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl gnupg

  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update -y
  $SUDO apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # $USER is not set when this runs from a cloud-init startup script, so fall
  # back to the real user, and never let this step abort the install.
  TARGET_USER="${USER:-$(id -un)}"
  if [[ "$TARGET_USER" == "root" ]] && id ubuntu >/dev/null 2>&1; then
    TARGET_USER="ubuntu"   # so you can run docker without sudo when you SSH in
  fi
  if id "$TARGET_USER" >/dev/null 2>&1; then
    $SUDO usermod -aG docker "$TARGET_USER" || warn "Could not add $TARGET_USER to the docker group."
    warn "Added $TARGET_USER to the docker group. Log out and back in for it to"
    warn "apply, or just use 'sudo docker ...' for now."
  fi
fi

$SUDO systemctl enable --now docker

# ------------------------------------------------------------- firewall ------
# Oracle's Ubuntu images ship a restrictive INPUT chain that drops everything
# not explicitly allowed. Opening the port in the OCI web console is only half
# the job; this is the other half, and it's where most people get stuck.
say "Opening UDP $PORT in the VM firewall"

if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  $SUDO ufw allow "${PORT}/udp"
  echo "    ufw rule added"
fi

if command -v iptables >/dev/null 2>&1; then
  if $SUDO iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    echo "    iptables rule already present"
  else
    # Insert before the catch-all REJECT that Oracle puts at the end.
    $SUDO iptables -I INPUT 6 -p udp --dport "$PORT" -j ACCEPT 2>/dev/null \
      || $SUDO iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
    echo "    iptables rule added"
  fi

  # Persist across reboots.
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | $SUDO debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | $SUDO debconf-set-selections
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  fi
  $SUDO netfilter-persistent save >/dev/null 2>&1 || warn "Could not persist iptables rules."
fi

warn "Don't forget the OTHER firewall: in the Oracle web console, add an"
warn "ingress rule for UDP $PORT to your VCN's security list. See README step 4."

# ------------------------------------------------------------------ swap -----
# 12 GB is ample, but a little swap stops an unlucky memory spike from killing
# the server outright.
if ! swapon --show | grep -q '/swapfile'; then
  say "Adding a 2 GB swap file"
  $SUDO fallocate -l 2G /swapfile
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile >/dev/null
  $SUDO swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
else
  say "Swap already configured — skipping"
fi

# ----------------------------------------------------------------- config ----
if [[ ! -f "$DIR/.env" ]]; then
  say "Creating .env from the example"
  cp "$DIR/.env.example" "$DIR/.env"
  warn "Edit $DIR/.env to set your server name and allowlist."
fi

mkdir -p "$DIR/data" "$DIR/backups"

# ---------------------------------------------------------------- backups ----
say "Scheduling nightly backups (05:00 server time)"
chmod +x "$DIR/backup.sh"
CRON_LINE="0 5 * * * $DIR/backup.sh >> $DIR/backups/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "$DIR/backup.sh" ; echo "$CRON_LINE" ) | crontab -

# ------------------------------------------------------------------ done -----
say "Setup complete"
cat <<EOF

Next:

  1. Edit your settings:      nano $DIR/.env
  2. Start the server:        cd $DIR && docker compose up -d
  3. Watch it boot:           docker compose logs -f
     (first start downloads the server and generates the world, ~2-5 minutes)

  Your server address:        $(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || echo '<your VM public IP>')
  Port:                       $PORT

EOF
