# infra

Personal NixOS infrastructure repo (multi-host, multi-app).

Currently deployed:
- `openclaw-prod` (Hetzner) running OpenClaw + `marmot-ts` over public Nostr relays.

NixOS deployment for OpenClaw on Hetzner Cloud.

## Quick Start (OpenClaw)

```bash
nix develop                  # enter dev shell with hcloud, just, sops, etc.
just setup                   # shows first-time instructions

# One-time: configure hcloud CLI
hcloud context create openclaw
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

## Notes

- Secrets are stored in `secrets/` as **sops-encrypted** YAML. No plaintext secrets are committed.
- This repo currently targets a single host; expect structure to evolve as more hosts/apps are added.

## Architecture (OpenClaw)

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

## Upgrading to Terraform

When you need multiple servers or DNS-as-code, write a `main.tf` describing the
existing server, then `terraform import hcloud_server.openclaw_prod <server-id>`.
The NixOS configuration stays identical.
