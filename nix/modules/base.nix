{ config, lib, pkgs, ... }:

{
  # Enable flakes
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [
      "https://cache.nixos.org"
      "https://cache.garnix.io"
    ];
    trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };

  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    helix
    git
    htop
    curl
    wget
    tmux
    jq
  ];

  # SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # SSH keys for root access
  users.users.root.openssh.authorizedKeys.keys = [
    # YubiKey primary
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIOvnevaL7FO+n13yukLu23WNfzRUPzZ2e3X/BBQLieapAAAABHNzaDo= justin@yubikey-primary"
    # YubiKey backup
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMrMVMYKXjA7KuxacP6RexsSfXrkQhwOKwGAfJExDxYZAAAABHNzaDo= justin@yubikey-backup"
    # 1Password backup (emergency)
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK9qcRB7tF1e8M9CX8zoPfNmQgWqvnee0SKASlM0aMlm mail@justinmoon.com"
    # infra deploy key
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHycGqFnrf8+1dmmI9CWRaADWrXMvnKWqx0UkpIFgXv1 infra"
  ];

  # Firewall — SSH, HTTP, HTTPS
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
  };

  time.timeZone = "UTC";

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
