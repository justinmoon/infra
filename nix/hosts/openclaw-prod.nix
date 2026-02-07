{ config, lib, pkgs, modulesPath, nix-openclaw, openclawSrc, marmotInteropRustSrc, ... }:

let
  # OpenClaw gateway port (systemd user service binds here, Caddy proxies to it)
  gatewayPort = 18789;
  # Computed via `nix build` on this flake when the hash mismatch is thrown.
  # Pinned hash for the forked OpenClaw gateway source (justinmoon/openclaw@9b05d1…).
  # To update: set to lib.fakeHash, build the pnpm deps derivation, then paste the "got:" hash.
  openclawPnpmDepsHash = "sha256-/LnHjVZTqGnc6KjKF2lM7eG2Qh2j5u4x8izXTRcuqvU=";
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/base.nix
    ../modules/caddy.nix
  ];

  networking.hostName = "openclaw-prod";

  # Needed for sops-nix runtime decryption (age) and for on-server debugging (sops).
  environment.systemPackages = with pkgs; [ age sops ];

  # Make nix-openclaw packages available system-wide (needed for HM module defaults)
  nixpkgs.overlays = [
    nix-openclaw.overlays.default
    (final: prev: let
      sourceInfo = import "${nix-openclaw}/nix/sources/openclaw-source.nix";
      openclawGateway = final.callPackage "${nix-openclaw}/nix/packages/openclaw-gateway.nix" {
        inherit sourceInfo;
        gatewaySrc = openclawSrc;
        pnpmDepsHash = openclawPnpmDepsHash;
      };
      # Keep the server closure small: we only need a basic toolchain for marmot-ts,
      # not the full "batteries" tool set (which includes heavy deps like openai-whisper/torch).
      toolSets = import "${nix-openclaw}/nix/tools/extended.nix" {
        pkgs = final;
        toolNamesOverride = [
          "nodejs_22"
          "pnpm_10"
          "git"
          "curl"
          "jq"
          "ripgrep"
        ];
      };
      openclawBundle = final.callPackage "${nix-openclaw}/nix/packages/openclaw-batteries.nix" {
        openclaw-gateway = openclawGateway;
        openclaw-app = null;
        extendedTools = toolSets.tools;
      };
      openclawTools = final.buildEnv {
        name = "openclaw-tools";
        paths = toolSets.tools;
        pathsToLink = [ "/bin" ];
      };

      # Marmot (Rust) sidecar binary. This is invoked by the Marmot channel plugin.
      marmotRustHarness =
        let
          marmotRustSrc = final.lib.cleanSourceWith {
            src = marmotInteropRustSrc;
            filter = path: type:
              let
                p = toString path;
                root = toString marmotInteropRustSrc + "/";
              in
                final.lib.any (prefix: final.lib.hasPrefix (root + prefix) p) [
                  "Cargo.toml"
                  "Cargo.lock"
                  "rust-toolchain.toml"
                  "rust_harness"
                ];
          };
        in
          final.rustPlatform.buildRustPackage {
            pname = "marmot-rust-harness";
            version = "0.1.0";
            src = marmotRustSrc;
            nativeBuildInputs = [ final.pkg-config ];
            buildInputs = [ final.openssl ];
            cargoLock = {
              lockFile = marmotRustSrc + "/Cargo.lock";
              # Git dependencies require outputHashes. Start with fake hashes; `nix build` will print the
              # correct values to paste here.
              outputHashes = {
                "mdk-core-0.5.3" = "sha256-jwQRszjNHiPwLOtnvpkn2aUawc9Da0mTLFO26Wnn5q4=";
                "mdk-sqlite-storage-0.5.1" = "sha256-jwQRszjNHiPwLOtnvpkn2aUawc9Da0mTLFO26Wnn5q4=";
                "mdk-storage-traits-0.5.1" = "sha256-jwQRszjNHiPwLOtnvpkn2aUawc9Da0mTLFO26Wnn5q4=";
                "openmls-0.7.1" = "sha256-dVIqNxTj3fHaeavExwqO5vtEULpMMNIb3GZHmjBJ+24=";
                "openmls_basic_credential-0.4.1" = "sha256-dVIqNxTj3fHaeavExwqO5vtEULpMMNIb3GZHmjBJ+24=";
                "openmls_memory_storage-0.4.1" = "sha256-dVIqNxTj3fHaeavExwqO5vtEULpMMNIb3GZHmjBJ+24=";
                "openmls_rust_crypto-0.4.1" = "sha256-dVIqNxTj3fHaeavExwqO5vtEULpMMNIb3GZHmjBJ+24=";
                "openmls_traits-0.4.1" = "sha256-dVIqNxTj3fHaeavExwqO5vtEULpMMNIb3GZHmjBJ+24=";
              };
            };
            cargoBuildFlags = [ "-p" "rust_harness" ];
          };
    in {
      openclaw-gateway = openclawGateway;
      openclaw = openclawBundle;
      openclaw-tools = openclawTools;
      marmot-rust-harness = marmotRustHarness;
    })
  ];

  # ── SOPS secrets ──────────────────────────────────────────────────────
  # The age key is deployed manually to /etc/age/key.txt after first boot.
  sops = {
    # Use the server's SSH host key as the age identity. This avoids a separate
    # manually-managed /etc/age key and is sufficient for NixOS secrets on a single host.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/openclaw.yaml;
  };

  # Optional: used only by the inference smoke test. Deterministic Marmot E2E does not require it.
  sops.secrets."openclaw/anthropic_api_key" = {
    format = "yaml";
    key = "anthropic_api_key";
    owner = "openclaw";
    group = "users";
    mode = "0400";
  };

  # Render a systemd-friendly env file without leaking secrets into the Nix store.
  sops.templates."openclaw-env" = {
    owner = "openclaw";
    group = "users";
    mode = "0400";
    content = ''
      # Generated by sops-nix. Do not edit.
      ANTHROPIC_API_KEY=${config.sops.placeholder."openclaw/anthropic_api_key"}
    '';
  };

  # ── OpenClaw user ─────────────────────────────────────────────────────
  users.users.openclaw = {
    isNormalUser = true;
    home = "/home/openclaw";
    extraGroups = [ ];
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
  };

  # ── Home Manager (OpenClaw gateway via nix-openclaw) ──────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # Make nix-openclaw overlay + HM module available
    sharedModules = [
      nix-openclaw.homeManagerModules.openclaw
    ];

    users.openclaw = { pkgs, ... }: {
      home.stateVersion = "24.11";

      # We manage the full OpenClaw config JSON (including the custom marmot-ts channel plugin)
      # ourselves. The nix-openclaw Home Manager module's typed config emitter would overwrite it.
      programs.openclaw.enable = false;

      # nix-openclaw's schema-typed config doesn't currently expose optional channel plugins like
      # `nostr` (and our in-flight `marmot-ts`). OpenClaw itself accepts these keys, so we write
      # the JSON directly to keep infra unblocked.
      #
      # Note: OpenClaw expands "${VAR}" in config values at runtime.
      home.file.".openclaw/openclaw.json" = {
        force = true;
        text = lib.mkForce (builtins.toJSON {
        # Deterministic agent workspace (mirrors our local gateway E2E).
        agents = {
          defaults = {
            workspace = "/home/openclaw/.openclaw/workspace";
            skipBootstrap = true;
            maxConcurrent = 1;
          };
          list = [
            {
              id = "marmot";
              default = true;
              workspace = "/home/openclaw/.openclaw/workspace";
              identity = {
                name = "Marmot Bot";
                theme = "deterministic";
                emoji = "";
              };
            }
          ];
        };

        gateway = {
          mode = "local";
          port = gatewayPort;
        };

        # Prefer environment-provided Anthropic API keys over any previously stored
        # OAuth/token profiles in the agent auth store.
        auth = {
          order = {
            anthropic = [];
          };
        };

        plugins = {
          enabled = true;
          # Optional plugins are "bundled (disabled by default)" unless explicitly enabled.
          entries = {
            "marmot-ts" = { enabled = true; };
            "marmot" = { enabled = true; };
          };
        };

        channels = {
          "marmot-ts" = {
            enabled = true;
            name = "Marmot (MLS)";
            # Popular public relays (as of 2026-02-07). Keep the list small for reliability.
            # Important: some public relays reject writes or can hang requests waiting for EOSE.
            relays = [
              "wss://relay.primal.net"
              "wss://nos.lol"
              "wss://relay.damus.io"
            ];
            # Keep deterministic probes working, but restrict the agent/LLM routing surface area:
            # only allow non-deterministic DMs from the owner allowlist.
            dmPolicy = "open";
            allowFrom = [
              "npub1zxu639qym0esxnn7rzrt48wycmfhdu3e5yvzwx7ja3t84zyc2r8qz8cx2y"
            ];
          };

          "marmot" = {
            enabled = true;
            name = "Marmot (Rust)";
            relays = [
              "wss://relay.primal.net"
              "wss://nos.lol"
              "wss://relay.damus.io"
            ];
            # MVP: allow list groups by default. Set to "open" only for controlled testing.
            groupPolicy = "allowlist";
            autoAcceptWelcomes = true;
            sidecarCmd = "${pkgs.marmot-rust-harness}/bin/rust_harness";
          };
        };
      });
      };

      # Install the Marmot (Rust) OpenClaw plugin source into ~/.openclaw/extensions/marmot.
      # OpenClaw will discover it as a "global" plugin.
      home.file.".openclaw/extensions/marmot" = {
        source = marmotInteropRustSrc + "/openclaw/extensions/marmot";
        recursive = true;
      };

      # Minimal deterministic workspace docs.
      home.file.".openclaw/workspace/AGENTS.md" = {
        force = true;
        text = ''
        # AGENTS.md

        Deterministic Marmot integration bot.
      '';
      };
      home.file.".openclaw/workspace/SOUL.md" = {
        force = true;
        text = ''
        # SOUL.md

        You are a deterministic test bot. When instructed to "reply exactly \"X\"", reply with exactly X and nothing else.
      '';
      };
      home.file.".openclaw/workspace/TOOLS.md" = {
        force = true;
        text = ''
        # TOOLS.md

        (no-op)
      '';
      };
      home.file.".openclaw/workspace/IDENTITY.md" = {
        force = true;
        text = ''
        # IDENTITY.md

        - Name: Marmot Bot
        - Theme: deterministic
      '';
      };
      home.file.".openclaw/workspace/USER.md" = {
        force = true;
        text = ''
        # USER.md

        - Name: openclaw-prod
      '';
      };
    };
  };

  # Run OpenClaw gateway as a system service (not a user service) so we can manage config via HM files.
  systemd.services.openclaw-gateway = {
    description = "OpenClaw gateway (OpenClaw user)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "sops-nix.service" ];
    wants = [ "network-online.target" "sops-nix.service" ];

    preStart = ''
      if [ -d /home/openclaw/.openclaw/channels ]; then
        chmod -R go-rwx /home/openclaw/.openclaw/channels || true
      fi
    '';

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "users";
      # The marmot-ts channel persists a Nostr secret key under $OPENCLAW_STATE_DIR.
      # Ensure files are not world-readable.
      UMask = "0077";
      WorkingDirectory = "/home/openclaw";
      Environment = [
        "HOME=/home/openclaw"
        "OPENCLAW_STATE_DIR=/home/openclaw/.openclaw"
        "CLAWDBOT_STATE_DIR=/home/openclaw/.openclaw"
        "OPENCLAW_CONFIG_PATH=/home/openclaw/.openclaw/openclaw.json"
        "CLAWDBOT_CONFIG_PATH=/home/openclaw/.openclaw/openclaw.json"
        # The gateway requires a shared secret even when bound to loopback.
        # This token is only used for local administration (the Marmot/Nostr channel
        # does not expose the token to peers).
        "OPENCLAW_GATEWAY_TOKEN=marmot-interop-lab-local"
        "RELAYS="
      ];
      EnvironmentFile = [
        # Optional: deterministic Marmot tests don't need Anthropic.
        ("-" + config.sops.templates."openclaw-env".path)
      ];
      ExecStart = "${pkgs.openclaw-gateway}/bin/openclaw gateway --port ${toString gatewayPort}";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Ensure the systemd user service starts at boot (without requiring login)
  # This is the lingering trick for user services.
  systemd.tmpfiles.rules = [
    "d /var/lib/systemd/linger 0755 root root -"
    "f /var/lib/systemd/linger/openclaw 0644 root root -"
  ];

  # ── Caddy reverse proxy ───────────────────────────────────────────────
  # Uncomment and set your domain once DNS is pointed at this server.
  # services.web = {
  #   enable = true;
  #   acmeEmail = "mail@justinmoon.com";
  #   sites = {
  #     "openclaw.example.com" = { port = gatewayPort; };
  #   };
  # };

  # ── Hetzner disk layout (disko) ──────────────────────────────────────
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/sda";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1M";
            type = "EF02"; # BIOS boot partition
          };
          esp = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  system.stateVersion = "24.11";
}
