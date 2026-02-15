set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Streambot Tailscale IP (SSH is Tailscale-only)
STREAMBOT_IP := env_var_or_default("STREAMBOT_IP", "100.83.137.37")

# List available commands
default:
    @just --list

# Create (if missing) and edit the local OpenAI key file for streambot, encrypted via sops.
#
# This keeps the OpenAI key out of git history while still letting the server decrypt it at
# activation time (using the host-key-derived age identity configured in nix/hosts/streambot.nix).
openclaw-local-init:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p secrets
    if [[ -f secrets/openclaw-local.yaml ]]; then
      echo "exists: secrets/openclaw-local.yaml"
      exit 0
    fi
    printf '%s\n' 'openai_api_key: ""' | sops \
      --encrypt \
      --input-type yaml \
      --output-type yaml \
      --filename-override secrets/openclaw-local.yaml \
      /dev/stdin > secrets/openclaw-local.yaml
    echo "created: secrets/openclaw-local.yaml"

openclaw-local-edit:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/configs/yubikeys/keys.txt}"
    just openclaw-local-init
    sops secrets/openclaw-local.yaml

openclaw-local-upload:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f secrets/openclaw-local.yaml ]]; then
      echo "missing secrets/openclaw-local.yaml; run: just openclaw-local-edit" >&2
      exit 1
    fi
    ssh streambot "sudo install -d -m 0750 -o root -g root /etc/openclaw"
    scp secrets/openclaw-local.yaml streambot:/tmp/openclaw-local.yaml
    ssh streambot "sudo install -m 0640 -o root -g root /tmp/openclaw-local.yaml /etc/openclaw/openclaw-local.yaml && sudo rm -f /tmp/openclaw-local.yaml"

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
    IP="{{STREAMBOT_IP}}"
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
        --flake ".#streambot" \
        --target-host "root@$IP" \
        -i ~/.ssh/openclaw_ed25519
    echo ""
    echo "==> NixOS installed! Server should reboot momentarily."
    echo "    SSH: ssh root@$IP"
    echo "    Deploy config updates: just deploy"

# Deploy NixOS config update (no wipe, just rebuild)
# Builds natively on Hetzner (x86_64-linux), then copies the closure
# directly from Hetzner's nix-serve cache to streambot over Tailscale.
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="{{STREAMBOT_IP}}"

    HETZNER="justin@100.73.239.5"
    HETZNER_SSH_OPTS="-i $HOME/.ssh/id_ed25519_hetzner"
    PROD_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
    REMOTE_DIR="/tmp/streambot-infra"
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
        "cd $REMOTE_DIR && nix build .#nixosConfigurations.streambot.config.system.build.toplevel --no-link --print-out-paths")
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
# Use this as fallback if Tailscale isn't available between Hetzner and streambot.
deploy-via-mac:
    #!/usr/bin/env bash
    set -euo pipefail
    IP="{{STREAMBOT_IP}}"
    echo "==> Deploying to $IP (via Mac, slow)..."
    NIX_SSHOPTS="-i $HOME/.ssh/openclaw_ed25519 -o StrictHostKeyChecking=accept-new" \
        nix run nixpkgs#nixos-rebuild -- switch \
        --flake ".#streambot" \
        --target-host "root@$IP" \
        --sudo
    echo "==> Done!"

# Show OpenClaw gateway status on remote
status:
    ssh streambot "systemctl status openclaw-gateway --no-pager -n 30 || true"

# Tail OpenClaw gateway logs on remote
logs:
    ssh streambot "journalctl -u openclaw-gateway -f"

# ── MoQ Relay Fleet ─────────────────────────────────────────────────────

# Relay server definitions: name → hetzner location
# relay-ash (us-east.moq.logos.surf) → Ashburn, VA      cpx11
# relay-hil (us-west.moq.logos.surf) → Hillsboro, OR    cpx11
# relay-fsn (germany.moq.logos.surf) → Nuremberg, DE    cpx22
# relay-sin (singapore.moq.logos.surf) → Singapore      cpx22

RELAY_TYPE := "cpx11"
HETZNER_BUILDER := "justin@100.73.239.5"
HETZNER_SSH_KEY := env_var_or_default("HETZNER_SSH_KEY", env_var("HOME") + "/.ssh/id_ed25519_hetzner")

# Create all 4 relay servers (Debian base, ready for nixos-anywhere)
relay-create-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for pair in "relay-ash:ash:cpx11" "relay-hil:hil:cpx11" "relay-fsn:nbg1:cpx22" "relay-sin:sin:cpx22"; do
      IFS=: read -r name loc type <<< "$pair"
      if hcloud server describe "$name" &>/dev/null; then
        IP=$(hcloud server ip "$name")
        echo "✓ $name already exists ($IP)"
      else
        echo "==> Creating $name in $loc ($type)..."
        hcloud server create \
          --name "$name" \
          --type "$type" \
          --location "$loc" \
          --image debian-12 \
          --ssh-key default
        IP=$(hcloud server ip "$name")
        echo "✓ $name created ($IP)"
      fi
    done
    echo ""
    echo "==> All relay servers created. IPs:"
    just relay-ips

# Show relay IPs (for DNS setup)
relay-ips:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "DNS records needed:"
    for pair in "relay-ash:us-east.moq.logos.surf" "relay-hil:us-west.moq.logos.surf" "relay-fsn:germany.moq.logos.surf" "relay-sin:singapore.moq.logos.surf"; do
      name="${pair%%:*}"
      domain="${pair##*:}"
      IP=$(hcloud server ip "$name" 2>/dev/null || echo "NOT CREATED")
      printf "  %-30s A → %s\n" "$domain" "$IP"
    done

# Initial deploy NixOS to a relay (wipes server)
relay-initial-deploy name:
    #!/usr/bin/env bash
    set -euo pipefail
    NAME="{{name}}"
    IP=$(hcloud server ip "$NAME")
    echo "==> Installing NixOS on $NAME ($IP) via nixos-anywhere..."
    echo "    This will WIPE the server and install NixOS from scratch."
    echo ""
    # Ensure flake inputs are up to date
    git add -A

    nix run github:nix-community/nixos-anywhere -- \
        --flake ".#$NAME" \
        --target-host "root@$IP" \
        --build-on remote
    echo ""
    echo "==> NixOS installed on $NAME! Server should reboot momentarily."
    echo "    SSH: ssh root@$IP"

# Initial deploy NixOS to ALL relays
relay-initial-deploy-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for name in relay-ash relay-hil relay-fsn relay-sin; do
      echo ""
      echo "════════════════════════════════════════"
      echo "  Deploying $name"
      echo "════════════════════════════════════════"
      just relay-initial-deploy "$name"
    done

# Deploy config update to a relay (builds on Hetzner dedicated, copies to relay)
relay-deploy name:
    #!/usr/bin/env bash
    set -euo pipefail
    NAME="{{name}}"
    IP=$(hcloud server ip "$NAME")
    BUILDER="{{HETZNER_BUILDER}}"
    BUILDER_SSH="-i {{HETZNER_SSH_KEY}}"
    REMOTE_DIR="/tmp/relay-infra"
    HETZNER_CACHE="http://100.73.239.5:5000"
    HETZNER_CACHE_KEY="hetzner-nix-cache:g8howY8l8I+SY+keoUMjm1OcXIagN065rdi8L11Fgvk="

    echo "==> Deploying $NAME ($IP)..."

    echo "  [1/4] Syncing config to Hetzner builder..."
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='result/' \
        -e "ssh $BUILDER_SSH" \
        ./ "$BUILDER:$REMOTE_DIR"
    ssh $BUILDER_SSH "$BUILDER" \
        "cd $REMOTE_DIR && (git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init) && git add --all" \
        2>/dev/null

    echo "  [2/4] Building on Hetzner (native x86_64-linux)..."
    SYSTEM=$(ssh $BUILDER_SSH "$BUILDER" \
        "cd $REMOTE_DIR && nix build .#nixosConfigurations.$NAME.config.system.build.toplevel --no-link --print-out-paths")
    echo "    Built: $SYSTEM"

    echo "  [3/4] Copying closure to $NAME..."
    ssh -o StrictHostKeyChecking=accept-new "root@$IP" \
        "nix copy --from '$HETZNER_CACHE' \
            --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= $HETZNER_CACHE_KEY' \
            '$SYSTEM'" || {
        echo "    Cache copy failed, trying direct nix copy from builder..."
        ssh $BUILDER_SSH "$BUILDER" \
            "nix copy --to ssh://root@$IP '$SYSTEM'"
    }

    echo "  [4/4] Activating..."
    ssh -o StrictHostKeyChecking=accept-new "root@$IP" \
        "nix-env -p /nix/var/nix/profiles/system --set '$SYSTEM' && '$SYSTEM'/bin/switch-to-configuration switch"

    echo "==> $NAME deployed!"

# Deploy config update to ALL relays
relay-deploy-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for name in relay-ash relay-hil relay-fsn relay-sin; do
      echo ""
      echo "════════════════════════════════════════"
      echo "  Deploying $name"
      echo "════════════════════════════════════════"
      just relay-deploy "$name"
    done

# SSH into a relay
relay-ssh name:
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(hcloud server ip "{{name}}")
    ssh -o StrictHostKeyChecking=accept-new "root@$IP"

# Show status of all relays
relay-status:
    #!/usr/bin/env bash
    set -euo pipefail
    for pair in "relay-ash:us-east.moq.logos.surf" "relay-hil:us-west.moq.logos.surf" "relay-fsn:germany.moq.logos.surf" "relay-sin:singapore.moq.logos.surf"; do
      name="${pair%%:*}"
      domain="${pair##*:}"
      IP=$(hcloud server ip "$name" 2>/dev/null || echo "")
      if [[ -z "$IP" ]]; then
        echo "✗ $name ($domain) — not created"
        continue
      fi
      STATUS=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$IP" \
        "systemctl is-active moq-relay 2>/dev/null" 2>/dev/null || echo "unreachable")
      echo "● $name ($domain) — $IP — moq-relay: $STATUS"
    done

# Destroy all relay servers
relay-destroy-all:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "This will destroy ALL relay servers!"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
    for name in relay-ash relay-hil relay-fsn relay-sin; do
      if hcloud server describe "$name" &>/dev/null; then
        hcloud server delete "$name"
        echo "✓ $name destroyed"
      else
        echo "  $name doesn't exist"
      fi
    done

# Setup: first-time hcloud CLI configuration
setup:
    @echo "First-time setup:"
    @echo ""
    @echo "1. Get a Hetzner Cloud API token from https://console.hetzner.cloud"
    @echo "   (Project → Security → API Tokens → Generate)"
    @echo ""
    @echo "2. Configure hcloud CLI:"
    @echo "   hcloud context create streambot"
    @echo "   # paste your API token when prompted"
    @echo ""
    @echo "3. Add your SSH key to Hetzner:"
    @echo "   hcloud ssh-key create --name default --public-key-from-file ~/.ssh/id_ed25519.pub"
    @echo ""
    @echo "4. Create server and deploy:"
    @echo "   just new              # create Debian server"
    @echo "   just initial-deploy   # install NixOS via nixos-anywhere"
    @echo "   just deploy           # subsequent config updates"
