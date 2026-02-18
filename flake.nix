{
  description = "Streambot infrastructure — Hetzner NixOS deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-openclaw = {
      url = "github:justinmoon/nix-openclaw/marmot-ts-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # OpenClaw gateway source (fork with marmot-ts extension + handleInboundMessage SDK fix)
    openclaw-src = {
      url = "github:justinmoon/openclaw/4dc532e2fd1a1228219bf3d538d43a36f9259a41";
      flake = false;
    };

    # Marmot OpenClaw extension plugin (archived; extension files only).
    openclawMarmotSrc = {
      url = "github:justinmoon/openclaw-marmot/audio-2";
      flake = false;
    };

    # Pika monorepo — source for the marmotd Rust sidecar binary.
    pikaSrc = {
      url = "github:sledtools/pika/master";
      flake = false;
    };

    # Media over QUIC relay
    moq = {
      url = "github:kixelated/moq";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, home-manager, nix-openclaw, openclaw-src, openclawMarmotSrc, pikaSrc, moq }:
  let
    systems = [ "x86_64-linux" "aarch64-darwin" ];

    # MoQ relay factory — lightweight single-purpose relay VPS.
    mkRelay = { hostname, domain }: nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit moq; };
      modules = [
        disko.nixosModules.disko
        moq.nixosModules.moq-relay
        (import ./nix/hosts/relay.nix { inherit hostname domain; })
      ];
    };

    streambot = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit nix-openclaw;
        openclawSrc = openclaw-src;
        inherit openclawMarmotSrc;
        inherit pikaSrc;
      };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        ./nix/hosts/streambot.nix
      ];
    };
  in {
    # NixOS server configuration
    nixosConfigurations.streambot = streambot;

    # MoQ relay edge nodes
    nixosConfigurations.relay-ash = mkRelay { hostname = "relay-ash"; domain = "us-east.moq.logos.surf"; };
    nixosConfigurations.relay-hil = mkRelay { hostname = "relay-hil"; domain = "us-west.moq.logos.surf"; };
    nixosConfigurations.relay-fsn = mkRelay { hostname = "relay-fsn"; domain = "germany.moq.logos.surf"; };
    nixosConfigurations.relay-sin = mkRelay { hostname = "relay-sin"; domain = "singapore.moq.logos.surf"; };

    # Convenience build targets (debugging / CI)
    packages.x86_64-linux.marmot-rust-harness = streambot.pkgs.marmot-rust-harness;

    # Dev shell with deployment tools
    devShells = nixpkgs.lib.genAttrs systems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        hc = pkgs.writeShellApplication {
          name = "hc";
          runtimeInputs = with pkgs; [ hcloud jq openssh coreutils ];
          text = builtins.readFile ./scripts/hc.sh;
        };
      in {
        default = pkgs.mkShell {
          packages = with pkgs; [
            hcloud
            jq
            just
            age
            age-plugin-yubikey
            sops
            nixos-rebuild
            hc
          ];
          shellHook = ''
            echo "Streambot Infra"
            echo "Commands: hc new | hc attach | hc destroy | hc list"
            echo "Deploy:   just initial-deploy | just deploy"
          '';
        };
      });
  };
}
