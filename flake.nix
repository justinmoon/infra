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
  };

  outputs = { self, nixpkgs, disko, sops-nix, home-manager, nix-openclaw, openclaw-src }:
  let
    systems = [ "x86_64-linux" "aarch64-darwin" ];
  in {
    # NixOS server configuration
    nixosConfigurations.openclaw-prod = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit nix-openclaw; openclawSrc = openclaw-src; };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        ./nix/hosts/openclaw-prod.nix
      ];
    };

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
