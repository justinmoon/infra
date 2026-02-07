{
  description = "OpenClaw infrastructure — Hetzner NixOS deployment";

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

    # OpenClaw gateway source (fork with marmot-ts extension)
    openclaw-src = {
      url = "github:justinmoon/openclaw/0cdfb2aab405ca392227de29dd91126df9f99528";
      flake = false;
    };

    # Local Marmot Rust track (for Marmot Rust sidecar + plugin source).
    marmotInteropLabRustSrc = {
      url = "github:justinmoon/marmot-interop-lab-rust/85a659b1d18c34388cb169a9b696792ef986488b";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, home-manager, nix-openclaw, openclaw-src, marmotInteropLabRustSrc }:
  let
    systems = [ "x86_64-linux" "aarch64-darwin" ];
    openclawProd = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit nix-openclaw;
        openclawSrc = openclaw-src;
        marmotInteropRustSrc = marmotInteropLabRustSrc;
      };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        ./nix/hosts/openclaw-prod.nix
      ];
    };
  in {
    # NixOS server configuration
    nixosConfigurations.openclaw-prod = openclawProd;

    # Convenience build targets (debugging / CI)
    packages.x86_64-linux.marmot-rust-harness = openclawProd.pkgs.marmot-rust-harness;

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
            sops
            nixos-rebuild
            hc
          ];
          shellHook = ''
            echo "OpenClaw Infra"
            echo "Commands: hc new | hc attach | hc destroy | hc list"
            echo "Deploy:   just initial-deploy | just deploy"
          '';
        };
      });
  };
}
