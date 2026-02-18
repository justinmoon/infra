{ config, lib, pkgs, modulesPath, nix-openclaw, openclawSrc, openclawMarmotSrc, pikaSrc, ... }:

let
  # OpenClaw gateway port (systemd user service binds here, Caddy proxies to it)
  gatewayPort = 18789;
  # Computed via `nix build` on this flake when the hash mismatch is thrown.
  # Pinned hash for the forked OpenClaw gateway source (justinmoon/openclaw@9b05d1…).
  # To update: set to lib.fakeHash, build the pnpm deps derivation, then paste the "got:" hash.
  openclawPnpmDepsHash = "sha256-bMIBp+PQnNxKC0BriKo/7VIg+C4TOPWb5PenQ9nSjFA=";

  # OpenClaw does not automatically restart when only HM-managed config files change.
  # Materialize the config as a Nix store path so we can wire it into restartTriggers.
  openclawConfig = {
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
        # Disabled until the marmot-ts extension is deployed to ~/.openclaw/extensions/marmot-ts.
        # The new OpenClaw version validates that referenced plugins exist on disk.
        # "marmot-ts" = { enabled = true; };

        # OpenClaw validates plugin entry config against the extension's configSchema.
        # The Marmot extension requires `relays`, so provide it here even though the
        # channel also has its own `channels.marmot.relays` config.
        "marmot" = {
          enabled = true;
          config = {
            relays = [
              "wss://relay.primal.net"
              "wss://nos.lol"
              "wss://relay.damus.io"
            ];
          };
        };
      };
    };

    channels = {
      # marmot-ts channel (TypeScript-native MLS). Disabled until the extension is deployed.
      # Uncomment when the marmot-ts extension directory is available.
      # "marmot-ts" = {
      #   enabled = true;
      #   name = "Marmot (MLS)";
      #   relays = [
      #     "wss://relay.primal.net"
      #     "wss://nos.lol"
      #     "wss://relay.damus.io"
      #   ];
      #   dmPolicy = "open";
      #   allowFrom = [];
      # };

      "marmot" = {
        enabled = true;
        name = "Marmot (Rust)";
        relays = [
          "wss://relay.primal.net"
          "wss://nos.lol"
          "wss://relay.damus.io"
        ];
        groupPolicy = "open";
        autoAcceptWelcomes = true;
        sidecarCmd = "${pkgs.marmot-rust-harness}/bin/marmotd";
        # --allow-pubkey is enforced in the Rust daemon: welcomes and messages
        # from any other pubkey are silently dropped before reaching OpenClaw.
        # Justin (real):  npub1zxu639qym0esxnn7rzrt48wycmfhdu3e5yvzwx7ja3t84zyc2r8qz8cx2y
        # Test key:       npub1y2z0c7un9dwmhk4zrpw8df8p0gh0j2x54qhznwqjnp452ju4078srmwp70
        # Paul:           npub1qjzr79nqfwducv4adfyg0zwl9qg4jvq9sspc8czsc0ekr8xm6ttsth5h4k
        sidecarArgs = [
          "daemon"
          "--relay" "wss://relay.primal.net"
          "--relay" "wss://nos.lol"
          "--relay" "wss://relay.damus.io"
          "--state-dir" "/home/openclaw/.openclaw/marmot/accounts/default"
          "--allow-pubkey" "11b9a894813efe60d39f8621ae9dc4c6d26de4732411c1cdf4bb15e88898a19c"
          "--allow-pubkey" "2284fc7b932b5dbbdaa2185c76a4e17a2ef928d4a82e29b812986b454b957f8f"
          "--allow-pubkey" "04843f16604b9bcc32bd6a488789df2811593005840383e050c3f3619cdbd2d7"
        ];
      };
    };
  };

  openclawConfigJson = pkgs.writeText "openclaw.json" (builtins.toJSON openclawConfig);
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/base.nix
    ../modules/caddy.nix
  ];

  networking.hostName = "streambot";

  # Tailscale-only admin access (no public SSH).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

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
      # Built from the pika monorepo (sledtools/pika). pikaSrc is a fixed-output flake input
      # so no source filtering is needed.
      marmotRustHarness =
          final.rustPlatform.buildRustPackage {
            pname = "marmot-rust-harness";
            version = "0.1.0";
            src = pikaSrc;
            nativeBuildInputs = [ final.pkg-config ];
            buildInputs = [ final.openssl ];
            cargoLock = {
              lockFile = pikaSrc + "/Cargo.lock";
              # Git dependencies require outputHashes. Start with fake hashes; `nix build` will print the
              # correct values to paste here.
              outputHashes = {
                "mdk-core-0.5.3" = "sha256-CfJnXuoCvG8EJrXGC89hwz1LOzfakR1j2A6uLMAFIE0=";
                "mdk-sqlite-storage-0.5.1" = "sha256-CfJnXuoCvG8EJrXGC89hwz1LOzfakR1j2A6uLMAFIE0=";
                "mdk-storage-traits-0.5.1" = "sha256-CfJnXuoCvG8EJrXGC89hwz1LOzfakR1j2A6uLMAFIE0=";
                "moq-lite-0.14.0" = "sha256-CVoVjbuezyC21gl/pEnU/S/2oRaDlvn2st7WBoUnWo8=";
              };
            };
            cargoBuildFlags = [ "-p" "marmotd" ];
            doCheck = false;
          };
    in {
      openclaw-gateway = openclawGateway;
      openclaw = openclawBundle;
      openclaw-tools = openclawTools;
      marmot-rust-harness = marmotRustHarness;
    })
  ];

  # ── SOPS secrets ──────────────────────────────────────────────────────
  sops = {
    # One-off age identity generated and deployed on the host:
    #   mkdir -p /etc/age && chmod 0700 /etc/age
    #   age-keygen -o /etc/age/key.txt && chmod 0400 /etc/age/key.txt
    age.keyFile = "/etc/age/key.txt";
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

  # Required for Marmot voice calls (STT/TTS) unless fixture mode is enabled.
  sops.secrets."openclaw/openai_api_key" = {
    format = "yaml";
    key = "openai_api_key";
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
      OPENAI_API_KEY=${config.sops.placeholder."openclaw/openai_api_key"}
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
    # Avoid failed activations due to pre-existing files in /home/openclaw/.openclaw.
    # Home Manager will move aside clashing files as *.hm-bak.
    backupFileExtension = "hm-bak";

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
        source = openclawConfigJson;
      };

      # Install the Marmot (Rust) OpenClaw plugin source into ~/.openclaw/extensions/marmot.
      # OpenClaw will discover it as a "global" plugin.
      home.file.".openclaw/extensions/marmot" = {
        source = openclawMarmotSrc + "/openclaw/extensions/marmot";
        recursive = true;
      };

      # Workspace identity files for the Marmot agent.
      home.file.".openclaw/workspace/AGENTS.md" = {
        force = true;
        text = ''
          # Agents

          This workspace is shared by the OpenClaw agent (Marmot Bot) and Pi.
          Both agents can read and write to the slipbox vault at /home/openclaw/slipbox/.
        '';
      };
      home.file.".openclaw/workspace/SOUL.md" = {
        force = true;
        text = ''
          # Soul

          You are Justin's personal knowledge assistant. You help manage a zettelkasten
          (slipbox) of 4000+ notes on history, philosophy, technology, politics, and more.

          You communicate over the Marmot protocol (MLS-encrypted messaging over Nostr).

          Be concise, thoughtful, and direct. When the user shares an idea, help them
          articulate it and save it as a note. When asked to find connections between
          ideas, search broadly and think carefully before responding.
        '';
      };
      home.file.".openclaw/workspace/TOOLS.md" = {
        force = true;
        text = ''
          # Tools

          Standard coding agent tools (bash, read, write, edit) are available.
          See the slipbox skill for API-based note management via slipboxd.
        '';
      };
      home.file.".openclaw/workspace/IDENTITY.md" = {
        force = true;
        text = ''
          # Identity

          - Name: Marmot Bot
          - Role: Personal knowledge assistant
          - Owner: Justin
        '';
      };
      home.file.".openclaw/workspace/USER.md" = {
        force = true;
        text = ''
          # User

          - Name: Justin
          - Interests: History (Rome, Japan, early America), philosophy, technology,
            political economy, Austrian economics, health/nutrition, programming
          - Style: Prefers concise, direct communication. Appreciates atomic notes
            (one idea per note) in the zettelkasten tradition.
        '';
      };
    };
  };

  # ── slipboxd — personal knowledge vault web server ─────────────────────
  systemd.services.slipboxd = {
    description = "slipboxd — Slipbox vault web server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # Defensive hardening: ensure slipboxd never binds to 0.0.0.0 (public or Tailscale).
    # slipboxd's current server.ts hardcodes 0.0.0.0, so we patch it on service start.
    preStart = ''
      if [ -f /home/openclaw/slipboxd/server.ts ]; then
        ${pkgs.gnused}/bin/sed -i \
          's/server\\.listen(PORT, "0\\.0\\.0\\.0"/server.listen(PORT, "127.0.0.1"/' \
          /home/openclaw/slipboxd/server.ts || true
      fi
    '';

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "users";
      WorkingDirectory = "/home/openclaw/slipboxd";
      ExecStart = "${pkgs.nodejs_22}/bin/node --experimental-strip-types server.ts --vault /home/openclaw/slipbox --port 7766";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = [ "NODE_NO_WARNINGS=1" ];
    };
  };

  # Run OpenClaw gateway as a system service (not a user service) so we can manage config via HM files.
  systemd.services.openclaw-gateway = {
    description = "OpenClaw gateway (OpenClaw user)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "sops-nix.service" "home-manager-openclaw.service" ];
    wants = [ "network-online.target" "sops-nix.service" "home-manager-openclaw.service" ];

    # Restart on deploy when the OpenClaw config/extension or env template changes.
    restartTriggers = [
      openclawConfigJson
      openclawMarmotSrc
      config.sops.templates."openclaw-env".path
    ];

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
        # Optional: enable a deterministic TTS greeting on call start for E2E automation.
        # Set to empty to disable.
        "MARMOT_CALL_START_TTS_TEXT=hello from streambot"
        "MARMOT_CALL_START_TTS_DELAY_MS=1500"
        # Real OpenAI STT/TTS for voice calls (requires OPENAI_API_KEY in env file).
        # Set MARMOT_TTS_FIXTURE=1 to fall back to deterministic tone without OpenAI.
        # "MARMOT_TTS_FIXTURE=1"
        # Debug: log sidecar request lifecycle (start/ok/error) at gateway level.
        "MARMOT_SIDECAR_LOG_REQUESTS=1"
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
    "d /etc/age 0700 root root -"
    "d /etc/openclaw 0750 root root -"
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
