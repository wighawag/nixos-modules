{
  config,
  lib,
  pkgs,
  ...
}:

# SEARXNG FOR THE MACHINE: an account-free metasearch backend on a UNIX SOCKET,
# which is what webveil (the CLI) and pi-webveil (the agent's web_search) query.
#
# The same recipe as the per-anon-account instances in ./anon-search.nix,
# which run on a real machine in the my-boxes fleet: uWSGI speaking HTTP on an
# inherited socket (`http-socket = fd://3`), socket-activated, so an idle
# machine carries a socket inode and no Python process. What differs is who it
# runs as (a system user rather than a jailed account) and who may connect (a
# group rather than one uid).
#
# WHY A SOCKET: access control is a file permission (the `clientGroup`),
# nothing listens on a port any local process could reach, and webveil speaks
# `unix:` natively. The instance's secret key is minted at every start and
# never written anywhere, so there is no secret to manage: it only signs
# SearXNG's own preference cookies, which nothing here uses.
#
# EGRESS: engine requests leave directly unless `egressProxies` says otherwise.
# Routing them through Tor (`socks5h://127.0.0.1:9050`) hides this machine's
# address from the engines, at the cost of many engines answering Tor exits
# with a captcha; that trade is measured in the my-boxes fleet's
# work/notes/findings/search-engine-gatekeeping-by-egress-class.md.
let
  cfg = config.nixos-modules.searxng;

  uwsgiPackage = pkgs.uwsgi.override {
    plugins = [ "python3" ];
    python3 = cfg.package.pythonModule;
  };
  pythonEnv = uwsgiPackage.python3.withPackages (_: [ cfg.package ]);

  # JSON, WHICH IS VALID YAML, written with writeText rather than
  # pkgs.formats.yaml. The content depends on installer answers (egress through
  # Tor or not), so an OFFLINE install builds this file on the target, and the
  # YAML generator needs remarshal, i.e. a Python toolchain the medium does not
  # carry: an offline install once set out to rebuild 1042 derivations for it.
  # writeText needs nothing but the builder that every system already has.
  settingsFile = pkgs.writeText "wasisabi-searxng-settings.yml" (
    builtins.toJSON (
    lib.recursiveUpdate {
      use_default_settings = true;
      general = {
        debug = false;
        instance_name = "wasisabi-search";
        contact_url = false;
      };
      search.formats = [
        "json"
        "html"
      ];
      server = {
        # Never used as a listen address (uWSGI serves the inherited socket),
        # but SearXNG validates that these exist.
        limiter = false;
        public_instance = false;
        bind_address = "127.0.0.1";
        port = 8888;
        # No secret_key here: SearXNG reads SEARXNG_SECRET from the
        # environment, which the start script mints.
      };
      outgoing = {
        request_timeout = cfg.requestTimeout;
      }
      // lib.optionalAttrs (cfg.egressProxies != [ ]) {
        proxies."all://" = cfg.egressProxies;
      };
    } cfg.settings
    )
  );

  uwsgiJson = pkgs.writeText "wasisabi-searxng-uwsgi.json" (
    builtins.toJSON {
      uwsgi = {
        strict = true;
        plugins = [ "python3" ];
        pyhome = "${pythonEnv}";
        module = "searx.webapp";
        # HTTP on the socket systemd passes as fd 3, NOT the native uwsgi
        # protocol: the client is an HTTP client (webveil), not a web server.
        http-socket = "fd://3";
        need-app = true;
        lazy-apps = true;
        enable-threads = true;
        buffer-size = 32768;
        master = true;
        processes = 1;
        die-on-term = true;
        env = [
          "PATH=${pythonEnv}/bin"
          "SEARXNG_SETTINGS_PATH=${settingsFile}"
        ];
      };
    }
  );

  startScript = pkgs.writeShellScript "wasisabi-searxng-start" ''
    set -euo pipefail
    SEARXNG_SECRET="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0)"
    export SEARXNG_SECRET
    exec ${uwsgiPackage}/bin/uwsgi --json ${uwsgiJson}
  '';
in
{
  options.nixos-modules.searxng = {
    enable = lib.mkEnableOption "a local SearXNG on a unix socket (webveil's search backend)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.searxng;
      defaultText = lib.literalExpression "pkgs.searxng";
      description = ''
        The SearXNG build. SearXNG is a pile of scrapers, so a newer build
        answers more often; a machine on a stable nixpkgs may want to point this
        at an unstable one. uWSGI is derived from this package's own
        interpreter, so both move together.
      '';
    };

    clientGroup = lib.mkOption {
      type = lib.types.str;
      default = "searxng-clients";
      description = "The group allowed to connect to the socket. Add a user to it to let them search.";
    };

    socketPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/wasisabi-search/search.sock";
      description = "READ-ONLY: where the instance serves, so consumers read one value.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "unix:${cfg.socketPath}";
      description = "READ-ONLY: the backend address in webveil's grammar, for webveil.json.";
    };

    egressProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "socks5h://127.0.0.1:9050" ];
      description = ''
        Proxies for the engines' outgoing requests; SearXNG cycles through the
        list per request. Empty (the default) means direct. `socks5h` resolves
        names at the proxy too, so DNS does not leak around it.
      '';
    };

    requestTimeout = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 6.0;
      description = "Seconds SearXNG waits for engines. Raise it when egress goes through Tor.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra SearXNG settings, merged over this module's (e.g. `engines`).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.clientGroup} = { };
    users.groups.searxng = { };
    users.users.searxng = {
      isSystemUser = true;
      group = "searxng";
      description = "wasisabi local SearXNG";
    };

    systemd.tmpfiles.rules = [
      "d /run/wasisabi-search 0750 searxng ${cfg.clientGroup} -"
    ];

    systemd.sockets.wasisabi-searxng = {
      description = "Local SearXNG socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketUser = "searxng";
        SocketGroup = cfg.clientGroup;
        SocketMode = "0660";
        RemoveOnStop = true;
      };
    };

    systemd.services.wasisabi-searxng = {
      description = "Local SearXNG (socket-activated)";
      requires = [ "wasisabi-searxng.socket" ];
      after = [
        "wasisabi-searxng.socket"
        "network.target"
      ];
      serviceConfig = {
        User = "searxng";
        Group = "searxng";
        ExecStart = startScript;
        StateDirectory = "wasisabi-searxng";
        StateDirectoryMode = "0700";
        Environment = [ "HOME=%S/wasisabi-searxng" ];
        Restart = "on-failure";
        RestartSec = 2;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = [ "native" ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
      };
    };
  };
}
