# infra

Streambot NixOS VPS — stream orchestration server on Hetzner Cloud.

## Quick Start

```bash
nix develop                  # enter dev shell with hcloud, just, sops, etc.
just setup                   # shows first-time instructions

# One-time: configure hcloud CLI
hcloud context create streambot
hcloud ssh-key create --name default --public-key-from-file ~/.ssh/id_ed25519.pub

# Create and deploy
just new                     # create Hetzner server (Debian base)
just initial-deploy          # install NixOS via nixos-anywhere
just deploy                  # subsequent config changes
```

## Commands

| Command | Description |
|---------|-------------|
| `just new` | Create Hetzner server |
| `just initial-deploy` | Install NixOS (wipes server) |
| `just deploy` | Push NixOS config updates |
| `just attach` | SSH into server |
| `just status` | Check gateway service status |
| `just logs` | Tail gateway logs |
| `just destroy` | Delete server |

## Architecture

```
┌─────────────────────────────────────────────┐
│              Your Mac                        │
│  nix develop → hc new → nixos-anywhere      │
│                  │                           │
│  nixos-rebuild switch --target-host root@IP  │
└──────────────────│──────────────────────────-┘
                   │ SSH
┌──────────────────▼──────────────────────────-┐
│           Hetzner VPS (cpx21)                │
│  ┌─────────────────────────────────────────┐ │
│  │              NixOS                       │ │
│  │  ┌───────────────────────────────────┐  │ │
│  │  │  openclaw user (home-manager)     │  │ │
│  │  │  • openclaw-gateway.service       │  │ │
│  │  │  • ~/.openclaw/openclaw.json      │  │ │
│  │  └───────────────────────────────────┘  │ │
│  │  ┌───────────────────────────────────┐  │ │
│  │  │  Caddy (reverse proxy + HTTPS)    │  │ │
│  │  └───────────────────────────────────┘  │ │
│  └─────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

## Cost

- **cpx21**: ~€0.014/hr (~€10/mo) — 3 vCPU, 4GB RAM, 80GB disk

## Notes

- Secrets are stored in `secrets/` as **sops-encrypted** YAML. No plaintext secrets are committed.
- The personal OpenClaw/Marmot/slipbox stack has been migrated to the Hetzner dedicated server (managed by `~/configs`).
- This VPS is being repurposed for stream orchestration tasks.
