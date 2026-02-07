set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Server IP (auto-detect from hc state, or override)
PROD_IP := env_var_or_default("PROD_IP", "")

# List available commands
default:
    @just --list

# Get server IP (from hc state file)
ip:
    @hc ip

# Create Hetzner server (Debian base)
new:
    hc new

# SSH into server
attach:
    hc attach

# Destroy server
destroy:
    hc destroy

# List servers
list:
    hc list

# Initial deploy: install NixOS on fresh Debian server via nixos-anywhere
initial-deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    if [[ -z "$IP" ]]; then
        echo "ERROR: No server IP. Run 'just new' first or set PROD_IP."
        exit 1
    fi
    echo "==> Installing NixOS on $IP via nixos-anywhere..."
    echo "    This will WIPE the server and install NixOS from scratch."
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    nix run github:nix-community/nixos-anywhere -- \
        --flake ".#openclaw-prod" \
        --target-host "root@$IP" \
        -i ~/.ssh/openclaw_ed25519
    echo ""
    echo "==> NixOS installed! Server should reboot momentarily."
    echo "    SSH: ssh root@$IP"
    echo "    Deploy config updates: just deploy"

# Deploy NixOS config update (no wipe, just rebuild)
# Uses the Hetzner remote builder for x86_64-linux builds.
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    if [[ -z "$IP" ]]; then
        echo "ERROR: No server IP. Run 'just new' first or set PROD_IP."
        exit 1
    fi
    echo "==> Deploying to $IP..."
    NIX_SSHOPTS="-i $HOME/.ssh/openclaw_ed25519 -o StrictHostKeyChecking=accept-new" \
        nixos-rebuild switch \
        --flake ".#openclaw-prod" \
        --target-host "root@$IP" \
        --sudo
    echo "==> Done!"

# Show OpenClaw gateway status on remote
status:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    ssh -i ~/.ssh/openclaw_ed25519 "root@$IP" "systemctl status openclaw-gateway --no-pager -n 30 || true"

# Tail OpenClaw gateway logs on remote
logs:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    ssh -i ~/.ssh/openclaw_ed25519 "root@$IP" "journalctl -u openclaw-gateway -f"

# Setup: first-time hcloud CLI configuration
setup:
    @echo "First-time setup:"
    @echo ""
    @echo "1. Get a Hetzner Cloud API token from https://console.hetzner.cloud"
    @echo "   (Project → Security → API Tokens → Generate)"
    @echo ""
    @echo "2. Configure hcloud CLI:"
    @echo "   hcloud context create openclaw"
    @echo "   # paste your API token when prompted"
    @echo ""
    @echo "3. Add your SSH key to Hetzner:"
    @echo "   hcloud ssh-key create --name default --public-key-from-file ~/.ssh/id_ed25519.pub"
    @echo ""
    @echo "4. Create server and deploy:"
    @echo "   just new              # create Debian server"
    @echo "   just initial-deploy   # install NixOS via nixos-anywhere"
    @echo "   just deploy           # subsequent config updates"
