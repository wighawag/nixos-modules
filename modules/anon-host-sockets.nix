# modules/anon-host-sockets.nix
#
# CLOSES THE DAEMON SOCKETS AN ANON LOGIN SHELL COULD STILL USE, box-wide rather
# than per unit. Sibling to modules/anon-nix-daemon.nix and modules/anon-dns.nix,
# and the same defect class: anonctl forces egress with `meta skuid <uid>`, the
# socket's OWNER, so a root-side daemon the account can ask to act for it does
# so in the clear, from the operator's address, with `anonctl verify` green.
#
# WHY A MODULE AND NOT JUST THE UNIT. modules/wherever-anon.nix already hides
# these sockets from the dashboard instances (InaccessiblePaths), which covers
# every session an agent runs there. A shell entered with `anonctl use` runs in
# the HOST's mount namespace, outside any unit, and was measured on telemaque
# (2026-09-27, as uid anon) reaching all of them:
#   - tailscaled: `tailscale status` printed the tailnet owner's login and every
#     peer, and `tailscale ping` got a pong from a peer. Its LocalAPI grants
#     every local uid read access and the dial/ping paths, and the dial is made
#     by tailscaled as root, on the operator's tailnet.
#   - systemd-resolved: `resolvectl query` (D-Bus) and a raw connect to its
#     varlink socket both worked, so any name resolves in resolved's process,
#     from the box's resolver. anon-dns removed the NSS route to resolved, not
#     the direct one.
#   - the D-Bus system bus: reachable, which is how resolvectl got there, and
#     on a desktop (wasisabi) it also reaches NetworkManager and friends.
#
# THREE LEVERS, each the narrowest that works for its daemon:
#   - tailscaled: its runtime directory becomes 0750 and group `tailscale.group`
#     (`users` by default, the operator's group), so the operator's own
#     `tailscale` keeps working and the anon accounts, which have DEDICATED
#     groups (modules/anon-accounts.nix), cannot traverse to the socket. The
#     group is set BEFORE tailscaled starts, so the socket never exists in a
#     reachable directory.
#   - resolved's varlink sockets: chmod 0600 right after resolved starts. Root
#     still connects; nothing else legitimately does once NSS no longer routes
#     through resolved (asserted below). resolved creates the sockets itself, so
#     there is a window between its start and this chmod; it is short and only
#     reopens when resolved restarts.
#   - the system bus: the anon LOGIN accounts are refused at connect, with a
#     `<deny user=...>` in the default context. Files from services.dbus.packages
#     are read after the stock `<allow user="*"/>`, and the later rule wins, so
#     the deny holds whatever policy another service ships. Refusing the whole
#     bus rather than resolve1 alone is deliberate: the set of bus services
#     differs per host and grows, and the dashboard instances already run with
#     no bus at all (Chromium only logs that it is absent). The SHIM accounts are
#     not refused: they run anonctl's relay and nothing else.
#
# DELIBERATELY LEFT OPEN: cups and avahi. Both reach only the local network, and
# on a desktop they are what printing and `.local` names are for. The dashboard
# instances do not see them; a login shell does.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.anonHostSockets;
  anon = config.nixos-modules.anonAccounts;

  logins = lib.attrNames anon.accounts;
  groupsOf = n: let u = config.users.users.${n}; in [u.group] ++ u.extraGroups;
  anonGroups = lib.unique (lib.concatMap groupsOf (logins ++ map (a: "${a}-shim") logins));

  # NSS entries that would route every getaddrinfo through resolved's varlink
  # socket, which the chmod below would then break for every non-root process.
  nssResolve = lib.filter (e: lib.head (lib.splitString " " e) == "resolve") config.system.nssDatabases.hosts;

  resolvedSockets = [
    "/run/systemd/resolve/io.systemd.Resolve"
    "/run/systemd/resolve/io.systemd.Resolve.Monitor"
  ];
  closeResolved = pkgs.writeShellScript "anon-close-resolved-varlink" ''
    for s in ${lib.escapeShellArgs resolvedSockets}; do
      if [ -S "$s" ]; then
        ${pkgs.coreutils}/bin/chmod 0600 "$s"
      else
        echo "anon-host-sockets: $s not present, nothing to close" >&2
      fi
    done
  '';

  busPolicy = pkgs.writeTextDir "share/dbus-1/system.d/nixos-modules-anon-deny.conf" ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <!-- nixos-modules/modules/anon-host-sockets.nix: the anon login accounts
         may not connect to the system bus at all. -->
    <busconfig>
      <policy context="default">
    ${lib.concatMapStrings (a: "    <deny user=\"${a}\"/>\n") logins}  </policy>
    </busconfig>
  '';
in {
  options.nixos-modules.anonHostSockets = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = anon.enable;
      defaultText = lib.literalExpression "config.nixos-modules.anonAccounts.enable";
      description = ''
        Close the root-side daemon sockets (tailscaled, systemd-resolved's
        varlink API, the D-Bus system bus) to the anon accounts box-wide, so a
        login shell from `anonctl use` cannot have a daemon egress for it
        outside anonctl's per-uid forcing. Each part is on only where its
        daemon runs; see the module header.
      '';
    };

    systemBus.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Refuse the anon login accounts a connection to the D-Bus system bus.";
    };

    resolvedVarlink.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.resolved.enable;
      defaultText = lib.literalExpression "config.services.resolved.enable";
      description = ''
        chmod systemd-resolved's varlink sockets to 0600 after it starts.
        Requires that no `resolve` NSS module is configured (modules/anon-dns.nix
        removes it), since every non-root lookup would otherwise break.
      '';
    };

    tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.services.tailscale.enable;
        defaultText = lib.literalExpression "config.services.tailscale.enable";
        description = "Restrict tailscaled's runtime directory (and so its LocalAPI socket) to `tailscale.group`.";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = ''
          The group that keeps access to the tailscale CLI. Must not be a group
          any anon account belongs to (asserted).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (cfg.systemBus.enable && logins != []) {
      services.dbus.packages = [busPolicy];
    })

    (lib.mkIf cfg.resolvedVarlink.enable {
      systemd.services.systemd-resolved.serviceConfig.ExecStartPost = ["+${closeResolved}"];
      assertions = [
        {
          assertion = nssResolve == [];
          message = ''
            nixos-modules.anonHostSockets.resolvedVarlink: system.nssDatabases.hosts
            routes lookups through systemd-resolved (${lib.concatStringsSep ", " nssResolve}).
            Closing resolved's varlink socket would break name resolution for
            every non-root process, and leaving it is the leak this closes.
            Enable nixos-modules.anonDns, which removes that entry.
          '';
        }
      ];
    })

    (lib.mkIf cfg.tailscale.enable {
      systemd.services.tailscaled.serviceConfig = {
        RuntimeDirectoryMode = lib.mkForce "0750";
        # RuntimeDirectory is created before ExecStartPre runs, so the group is
        # in place before tailscaled creates its socket.
        ExecStartPre = ["+${pkgs.coreutils}/bin/chgrp ${cfg.tailscale.group} /run/tailscale"];
      };
      assertions = [
        {
          assertion = !(lib.elem cfg.tailscale.group anonGroups);
          message = ''
            nixos-modules.anonHostSockets.tailscale.group is "${cfg.tailscale.group}", which an
            anon account belongs to, so the account would keep tailscaled's
            LocalAPI: tailnet status (the owner's login) and daemon-made dials.
          '';
        }
      ];
    })
  ]);
}
