{
  config,
  lib,
  pkgs,
  ...
}:

# WHEREVER FOR THE MACHINE'S OWNER: a web UI driving pi agent sessions, served
# on loopback, running AS the owner (sessions act in their home, on their
# repositories, with their identity).
#
# The laptop-shaped counterpart of the my-boxes fleet's `services.wherever`,
# which fronts it with Caddy/ACME on a mesh name and takes its token and config
# markers from sops. Here there is no secret manager to assume, so:
#
#   - THE TOKEN IS MINTED ON THE MACHINE, at first start, into the state
#     directory, readable by the owner only. It never exists in the store, in
#     the flake or in git, so a published configuration leaks nothing.
#     `wherever-link` prints the URL with the token in its fragment.
#   - THE CONFIG IS PLAIN DATA (`settings`), rendered into the store. It must
#     therefore hold no secret, which is also why there is no marker vocabulary.
#   - LOOPBACK AND PLAIN HTTP. A loopback origin is a secure context to every
#     browser, and nothing off this machine can connect. Reaching it from a
#     phone is a deliberate widening (a reverse proxy with TLS, or a mesh),
#     which this module leaves to the machine's own configuration.
let
  cfg = config.nixos-modules.wherever;
  home = config.users.users.${cfg.user}.home or "/home/${cfg.user}";
  uid = config.users.users.${cfg.user}.uid or null;
  stateDir = "/var/lib/wherever";
  tokenFile = "${stateDir}/token";

  configDir = pkgs.writeTextDir "config.json" (builtins.toJSON cfg.settings);

  mintToken = pkgs.writeShellScript "wherever-mint-token" ''
    set -eu
    if [ ! -s ${tokenFile} ]; then
      umask 077
      ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0 | tr '+/' '-_' | tr -d '=' > ${tokenFile}.new
      mv ${tokenFile}.new ${tokenFile}
    fi
    chown ${cfg.user} ${tokenFile}
    chmod 0400 ${tokenFile}
  '';

  linkCommand = pkgs.writeShellScriptBin "wherever-link" ''
    # Prints the URL of this machine's wherever, token included. The token is
    # in the FRAGMENT, which a browser never sends to the server, so it cannot
    # reach a log; wherever adopts it from there and strips it from the bar.
    if [ ! -r ${tokenFile} ]; then
      echo "wherever-link: cannot read ${tokenFile} (it belongs to ${cfg.user}; is wherever running?)" >&2
      exit 1
    fi
    echo "http://127.0.0.1:${toString cfg.port}/#token=$(cat ${tokenFile})"
  '';
in
{
  options.nixos-modules.wherever = {
    enable = lib.mkEnableOption "wherever, a web UI for pi agent sessions, for the machine's owner (loopback only)";

    package = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.wherever;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.wherever";
      description = "The wherever server package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "The human account wherever runs as. Sessions act with this account's identity, home and files.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 31415;
      description = "The loopback port.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = lib.literalExpression ''{ commonFolders = [ "dev" ]; sessions.maxAgeDays = 120; }'';
      description = ''
        wherever's config.json, as data. Rendered into the world-readable store,
        so it must hold no secret.
      '';
    };

    sessionPath = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.package lib.types.str);
      default = [ ];
      description = ''
        Extra PATH entries for every session. Appended after the guaranteed
        tools (git, ssh, bash, the system profile), so they add but never shadow.
      '';
    };

    allowPrivilegeEscalation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Let `sudo` work inside wherever sessions, which is what makes
        wherever's own sudo prompt usable: when YOU type `!sudo ...` in the web
        UI, it asks you for your password in a masked field and passes it to
        sudo once, without storing it.

        This does not make sudo ambient: sudo still wants the password
        (NixOS's default), and an agent does not know it. What it changes is
        whether the password CAN work at all. With it off, the unit sets
        NoNewPrivileges, the kernel ignores setuid, and sudo refuses whatever
        is typed.

        Turn it off on a machine whose owner has passwordless sudo (the live
        ISO does), since there it would hand agents root.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      description = ''
        Hard memory ceiling for the server AND every session it hosts. The point
        is that a runaway session can never take the desktop down with it.
        Node sizes its heap from the cgroup, so this also bounds each session.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ linkCommand ];

    # The CLI bridge (`pi` started from a terminal, joining the UI) reads this
    # same file; `remote.insecure` because the server speaks plain HTTP here.
    systemd.tmpfiles.rules = [
      "d ${home}/.wherever 0755 ${cfg.user} users - -"
      "L+ ${home}/.wherever/config.json - - - - ${configDir}/config.json"
    ];

    systemd.services.wherever = {
      description = "wherever (web UI for pi agent sessions), loopback only";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      path = [
        pkgs.git
        pkgs.openssh
        pkgs.bash
        "/run/current-system/sw"
      ]
      ++ cfg.sessionPath;
      environment = {
        HOME = home;
        WHEREVER_CONFIG_DIR = "${configDir}";
        WHEREVER_STATE_DIR = stateDir;
        WHEREVER_TOKEN_FILE = tokenFile;
      }
      // lib.optionalAttrs (uid != null) {
        XDG_RUNTIME_DIR = "/run/user/${toString uid}";
      };
      serviceConfig = {
        Type = "simple";
        # `+`: minting the token needs root to chown it to the owner.
        ExecStartPre = [ "+${mintToken}" ];
        ExecStart = "${cfg.package}/bin/wherever start --host 127.0.0.1 --port ${toString cfg.port} --http";
        Restart = "on-failure";
        RestartSec = "5s";
        User = cfg.user;
        Group = "users";
        StateDirectory = "wherever";
        StateDirectoryMode = "0700";
        MemoryMax = cfg.memoryMax;
        # See allowPrivilegeEscalation: with it off, a `sudo` a session runs is
        # refused by the kernel, password or not.
        NoNewPrivileges = !cfg.allowPrivilegeEscalation;
      };
    };
  };
}
