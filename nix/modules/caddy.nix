{ config, lib, pkgs, ... }:

let
  cfg = config.services.web;
in {
  options.services.web = {
    enable = lib.mkEnableOption "Web reverse proxy (Caddy)";

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      description = "Email address for ACME certificate notifications";
    };

    sites = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.port = lib.mkOption {
          type = lib.types.port;
          description = "Upstream port for this site";
        };
        options.extraConfig = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          description = "Extra Caddy config inserted before reverse_proxy";
        };
      });
      default = {};
      description = "Map of domain -> { port, extraConfig } for reverse proxy sites";
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;

      virtualHosts = lib.mapAttrs (domain: site: {
        extraConfig = ''
          ${lib.optionalString (site.extraConfig != null) site.extraConfig}
          reverse_proxy 127.0.0.1:${toString site.port}
        '';
      }) cfg.sites;
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
