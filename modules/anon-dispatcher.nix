{
  config,
  lib,
  pkgs,
  ...
}:

# THE ANON DISPATCHER, LOCAL-ONLY: one Caddy site that routes an opaque handle
# to one anon account's wherever socket, reachable from THIS machine only.
#
#   http://<handle>.localhost:<port>/#token=<token>
#
# This is the laptop-shaped version of the my-boxes fleet's dispatcher (its
# modules/reverse-proxy.nix `anonDispatcher`), which serves a wildcard
# certificate on a real domain so a phone can reach it over a mesh. The routing
# half is identical and was carried over unchanged: the store config holds the
# wildcard site and a glob `import` and NOTHING else (no account name, no
# handle, no socket path), and reconcile writes one fragment per account
# outside the store. What changed is the transport:
#
#   - `*.localhost` resolves to loopback by specification (RFC 6761), in every
#     current browser and in glibc through nss-myhostname, so there is no DNS
#     record, no domain and no certificate to own.
#   - plain HTTP on a loopback bind. A loopback origin is a secure context to
#     browsers, and the traffic never leaves the machine, so TLS here would be
#     ceremony. The bind is what keeps it local: nothing but this machine can
#     connect, whatever the firewall says.
#
# The token stays in the URL FRAGMENT, which is never sent to the server, so it
# cannot reach Caddy's access log either way.
#
# Reaching an anon interface from another device is deliberately not offered
# here. The fleet version exists for that and carries the costs that come with
# it (a domain, DNS-01, certificate transparency); a machine that wants it
# should use that shape rather than widen this bind.
let
  cfg = config.nixos-modules.anonDispatcher;

  # See the fleet module for why this is `-+`: `+` runs the guard as root (the
  # fragments are 0640 root:caddy), `-` means a bug in the guard can never be
  # the reason this machine has no web server.
  guardExec = "-+${lib.getExe cfg.guardPackage} --routes-dir ${cfg.routesDir} --quarantine-dir ${cfg.quarantineDir} --caddy ${lib.getExe config.services.caddy.package} --config ${cfg.configPath}";
in
{
  options.nixos-modules.anonDispatcher = {
    enable = lib.mkEnableOption ''
      a loopback-only Caddy site routing opaque handles to the per-account anon
      wherever sockets, from fragments reconcile writes at runtime
    '';

    domain = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = ''
        The wildcard site's parent name, so a handle becomes `<handle>.<domain>`.
        "localhost" is what makes this need no DNS at all; change it only if you
        also make the names resolve.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8480;
      description = "The loopback port the site listens on.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Where the site listens. LOOPBACK BY DEFAULT, and that bind is the whole
        access boundary: each interface is still token-gated by wherever itself,
        but an unreachable interface cannot be probed at all.
      '';
    };

    guardPackage = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.caddy-routes-guard;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.caddy-routes-guard";
      description = ''
        The start-time guard that quarantines a fragment which would stop the
        config adapting. Without it one bad fragment keeps Caddy down after the
        next restart, because a start failure is never retried.
      '';
    };

    routesDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/caddy/anon-routes";
      description = ''
        Directory of per-account fragments, glob-imported at load. Outside the
        store, because its contents are observed state (which handle maps to
        which account's socket). A missing or empty directory is valid to Caddy,
        so a machine with no anon account in use serves normally.
      '';
    };

    quarantineDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/caddy-anon-routes-quarantine";
      description = "Where the guard moves a fragment that breaks the config. Must be outside routesDir.";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/caddy/caddy_config";
      description = ''
        The Caddyfile the caddy unit actually runs, which the guard validates.
        Mirrors nixpkgs' private `etcConfigFile` in its caddy module.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      virtualHosts."http://*.${cfg.domain}:${toString cfg.port}" = {
        listenAddresses = [ cfg.bindAddress ];
        extraConfig = ''
          import ${cfg.routesDir}/*.caddy
          # An unclaimed handle must be indistinguishable from one never
          # allocated, or the response itself tells a prober which exist.
          respond 404
        '';
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.routesDir} 0755 root root -"
      "d ${cfg.quarantineDir} 0700 root root -"
    ];

    systemd.services.caddy.serviceConfig.ExecStartPre = [ guardExec ];
  };
}
