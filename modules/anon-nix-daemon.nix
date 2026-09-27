# modules/anon-nix-daemon.nix
#
# KEEPS ANON ACCOUNTS OFF THE NIX DAEMON, because the daemon is an unforced
# egress path any uid can drive. Sibling to modules/anon-dns.nix and the same
# class of defect: anonctl forces egress with `meta skuid <uid>`, which matches a
# socket's OWNER, so any work the account hands to a daemon running under
# another uid leaves the box in the clear, from the operator's address, while
# `anonctl verify` stays green.
#
# THE NIX DAEMON IS THE WORST SUCH DAEMON ON A NIXOS BOX. Its socket
# (/nix/var/nix/daemon-socket/socket) is mode 0666 and NixOS's default is
# `allowed-users = *`, so an anon session can ask it to:
#   - SUBSTITUTE: `nix shell nixpkgs#foo` makes the daemon fetch from the
#     binary caches as root, naming exactly which store paths the account wants;
#   - BUILD A FIXED-OUTPUT DERIVATION: `fetchurl { url = ...; hash = ...; }`
#     runs in a nixbld sandbox that HAS network, so the daemon GETs any URL the
#     session names and drops the body in the world-readable store. That is a
#     general-purpose, readable, unjailed fetch, not merely a metadata leak.
# Neither needs any privilege beyond "allowed-users". It is also exactly what an
# agent reaches for when a tool is missing, which is the ordinary case rather
# than an adversarial one.
#
# NIX HAS NO DENY LIST, so this is an allowlist. `allowed-users` takes user
# names and `@group`s and cannot subtract, so the only way to exclude the anon
# accounts is to name who IS allowed. The default (`root`, `@wheel`, `@users`)
# covers the operator and every normal user NixOS creates (GROUP=100), and it
# excludes every anon slot because modules/anon-accounts.nix gives each one a
# DEDICATED group and never adds it to wheel. The assertions below refuse any
# configuration in which that stops being true, including through
# `trusted-users`, which Nix treats as allowed regardless of `allowed-users`.
#
# WHAT THIS DOES NOT COVER, stated so nobody assumes it does: the other daemons
# an anon uid can reach over a world-connectable unix socket (systemd-resolved's
# varlink and D-Bus APIs, tailscaled, cups, avahi). Those cannot be switched off
# per uid by any setting of theirs, so they are hidden per UNIT instead, in
# modules/wherever-anon.nix (InaccessiblePaths). A login shell entered with
# `anonctl use` runs outside that unit and still sees them.
{
  config,
  lib,
  ...
}: let
  cfg = config.nixos-modules.anonNixDaemon;
  anon = config.nixos-modules.anonAccounts;

  # Every passwd name the anon pool declares, both halves of each slot: a shim
  # uid reaching the daemon would be just as unforced.
  anonNames = lib.concatMap (a: [a "${a}-shim"]) (lib.attrNames anon.accounts);
  groupsOf = n: let u = config.users.users.${n}; in [u.group] ++ u.extraGroups;
  anonGroups = lib.unique (lib.concatMap groupsOf anonNames);

  # An entry grants an anon account if it is the wildcard, the account's own
  # name, or a group the account is in.
  grantsAnon = e:
    e == "*"
    || lib.elem e anonNames
    || (lib.hasPrefix "@" e && lib.elem (lib.removePrefix "@" e) anonGroups);

  offending = setting: lib.filter grantsAnon (config.nix.settings.${setting} or []);
in {
  options.nixos-modules.anonNixDaemon = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = anon.enable;
      defaultText = lib.literalExpression "config.nixos-modules.anonAccounts.enable";
      description = ''
        Restrict the nix daemon to `allowedUsers`, and refuse any `allowed-users`
        or `trusted-users` entry that would let an anon account connect to it.

        ON BY DEFAULT WHEREVER ANON ACCOUNTS ARE DECLARED, because the daemon
        substitutes and fetches fixed-output derivations as root, outside
        anonctl's per-uid forcing: left open, an anon session can fetch any URL
        in the clear from the operator's address.
      '';
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["root" "@wheel" "@users"];
      description = ''
        Written to `nix.settings.allowed-users` (at mkDefault priority, so a host
        that sets that option directly wins, and is still checked). Must not
        include `*`, any anon account, or any group an anon account belongs to.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && config.nix.enable) {
    nix.settings.allowed-users = lib.mkDefault cfg.allowedUsers;

    assertions = [
      {
        assertion = offending "allowed-users" == [];
        message = ''
          nixos-modules.anonNixDaemon: nix.settings.allowed-users lets an anon
          account reach the nix daemon (offending: ${lib.concatStringsSep ", " (offending "allowed-users")}).
          The daemon substitutes and fetches as root, outside anonctl's per-uid
          forcing, so that account could fetch any URL in the clear. Name the
          allowed users explicitly; Nix has no way to exclude one.
        '';
      }
      {
        assertion = offending "trusted-users" == [];
        message = ''
          nixos-modules.anonNixDaemon: nix.settings.trusted-users names an anon
          account or one of its groups (offending: ${lib.concatStringsSep ", " (offending "trusted-users")}).
          Nix lets a trusted user connect whatever allowed-users says, and a
          trusted user can also change substituters and disable the sandbox.
        '';
      }
    ];
  };
}
