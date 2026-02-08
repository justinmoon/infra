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
# Builds natively on Hetzner (x86_64-linux), then copies the closure
# directly from Hetzner's nix-serve cache to prod over Tailscale.
# Requires: prod is on Tailscale (run `tailscale up` on prod first).
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    if [[ -z "$IP" ]]; then
        echo "ERROR: No server IP. Run 'just new' first or set PROD_IP."
        exit 1
    fi

    HETZNER="justin@100.73.239.5"
    HETZNER_SSH_OPTS="-i $HOME/.ssh/id_ed25519_hetzner"
    PROD_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
    REMOTE_DIR="/tmp/openclaw-infra"
    HETZNER_CACHE="http://100.73.239.5:5000"
    HETZNER_CACHE_KEY="hetzner-nix-cache:g8howY8l8I+SY+keoUMjm1OcXIagN065rdi8L11Fgvk="

    echo "==> Step 1/4: Syncing config to Hetzner builder..."
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='result/' \
        -e "ssh $HETZNER_SSH_OPTS" \
        ./ "$HETZNER:$REMOTE_DIR"
    # Flakes need git tracking
    ssh $HETZNER_SSH_OPTS "$HETZNER" \
        "cd $REMOTE_DIR && (git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init) && git add --all" \
        2>/dev/null

    echo "==> Step 2/4: Building on Hetzner (native x86_64-linux)..."
    SYSTEM=$(ssh $HETZNER_SSH_OPTS "$HETZNER" \
        "cd $REMOTE_DIR && nix build .#nixosConfigurations.openclaw-prod.config.system.build.toplevel --no-link --print-out-paths")
    echo "    Built: $SYSTEM"

    echo "==> Step 3/4: Copying closure from Hetzner cache to prod (Tailscale)..."
    ssh $PROD_SSH_OPTS "root@$IP" \
        "nix copy --from '$HETZNER_CACHE' \
            --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= $HETZNER_CACHE_KEY' \
            '$SYSTEM'"

    echo "==> Step 4/4: Activating on prod..."
    ssh $PROD_SSH_OPTS "root@$IP" \
        "nix-env -p /nix/var/nix/profiles/system --set '$SYSTEM' && '$SYSTEM'/bin/switch-to-configuration switch"

    echo "==> Done!"

# Deploy via Mac (old method, slow — copies 4.7GB closure through Mac).
# Use this as fallback if Tailscale isn't available between Hetzner and prod.
deploy-via-mac:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    if [[ -z "$IP" ]]; then
        echo "ERROR: No server IP. Run 'just new' first or set PROD_IP."
        exit 1
    fi
    echo "==> Deploying to $IP (via Mac, slow)..."
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
    ssh "root@$IP" "systemctl status openclaw-gateway --no-pager -n 30 || true"

# Tail OpenClaw gateway logs on remote
logs:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="${PROD_IP:-$(hc ip)}"
    ssh "root@$IP" "journalctl -u openclaw-gateway -f"

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
