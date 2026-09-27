# modules/anon-accounts.nix
#
# DECLARED SLOTS for anonctl's anon accounts, so that a box running
# `users.mutableUsers = false` can run anonctl at all. Declares users and
# NOTHING else -- no nftables, no shim unit, no anonctl invocation. anonctl still
# owns the forcing; this module owns only the passwd entries it forces.
#
# WHY THIS EXISTS, and it is a fail-OPEN hazard rather than a convenience.
# anonctl creates its accounts out of band (`useradd`, via anoncore/provision),
# so they are undeclared by construction. NixOS with `mutableUsers = false`
# treats the Nix configuration as the authoritative user database and REMOVES
# any undeclared account on every activation -- which means every boot and every
# `nixos-rebuild switch`. Measured on telemaque 2026-09-21, the boot ordering
# says it plainly (anonctl's own
# work/notes/findings/nixos-account-conventions-break-anonctl-provisioning.md):
#
#   13:29:41  NixOS Activation ...              <- deletes both accounts
#   13:29:42  anonctl-nftables.service Finished <- restores forcing for uid
#                                                  1002 / 992, deleted 1s ago
#
# What survives is worse than nothing: nft tables, the shim unit, the home
# directory and /etc/anonctl/accounts/<account>.json all still reference UIDs
# that are now FREE FOR REALLOCATION, while the ledger still records the account
# as jailed. Two ways that bites, both silent:
#
#   - UID REUSE JAILS A STRANGER. The next account NixOS creates can be handed
#     that uid and silently inherits the forcing: every TCP connection
#     redirected into a shim it knows nothing about.
#   - RECREATION UNJAILS THE REAL ACCOUNT. Recreate the anon account and it may
#     get a DIFFERENT uid. The old rules then match nobody, the new account is
#     completely unforced, and /etc/anonctl still says it is jailed. That is the
#     exact "still exists, still looks anonymised" failure anonctl exists to
#     prevent, reached from a direction its design did not anticipate.
#
# THE ALTERNATIVE WE REJECTED: `users.mutableUsers = true`. It stops the
# deletion, but on NixOS a declarative password is applied to an account that
# ALREADY EXISTS only when mutableUsers is FALSE -- update-users-groups.pl does
# `$sp_pwdp = $u->{hashedPassword} if defined $u->{hashedPassword} &&
# !$spec->{mutableUsers}; # FIXME`, and `hashedPasswordFile` is read into that
# same field so it passes through the same gate. telemaque manages root's and
# the operator's passwords through sops (hosts/telemaque/default.nix), so
# flipping the flag would make both advisory: rotate the secret, deploy it, and
# the box silently keeps the old password. That is the 2026-09-15 incident this
# fleet already had once. Declaring the accounts costs nothing by comparison.
#
# PINNED UIDS ARE THE POINT, not tidiness. A pinned uid is what closes the
# "UID reuse jails a stranger" hole above: the number cannot drift, so an
# orphaned table can only ever name the account it was written for. Pick them
# AWAY FROM BOTH ALLOCATION FRONTS, because NixOS allocates system uids
# DESCENDING from 999 and normal uids ASCENDING from 1000 (allocUid in
# update-users-groups.pl: `($min,$max,$delta) = $isSystemUser ? (400,999,-1) :
# (1000,29999,1)`). A declared uid is excluded from allocation, so any free
# number is CORRECT, but one taken from the middle of the range is also STABLE:
# it will not be contended as services come and go. Hence 11xx for logins
# (ascending front is at 1002) and 44x for shims (descending front is at 992).
#
# NAMING IS A PRIVACY CONTROL, AND sops CANNOT HELP. An account name is
# structurally public on the machine: /etc/passwd is world-readable, so is
# /nix/store/<hash>-users-groups.json (52 names in plaintext on telemaque),
# /home/<account> is a directory anyone can stat, and `anonctl-shim@<account>`
# is a unit name any unprivileged `systemctl list-units` prints. On top of that
# the name sits in this repo's git history. No secret-management tool closes
# this: Nix evaluates `users.users.<name>` at BUILD time whereas sops-nix
# decrypts at ACTIVATION time, so an encrypted value can never become an account
# name, and if it somehow did the result would land in that world-readable store
# path anyway.
#
# So the name MUST carry no information. Use SLOT IDS (`anon`, `anon-01`) or
# placeholder personas that say as little (`anon-john`, `anon-jane`: John and
# Jane Doe, which is what telemaque uses because they are easier to remember),
# never a purpose and never a real name, and keep the slot-to-purpose mapping in
# the operator's own secret store. anoncore builds `anon-<name>` and
# `<account>-shim` from whatever is passed (anoncore/account/account.go), so the
# part after `anon-` is exactly what `anonctl add` takes (`anonctl add john`).
#
# AND DECLARE THE POOL IN ONE COMMIT. A slot added later leaks TIMING -- when an
# identity was created -- which is often the most sensitive fact available, and
# a live passwd file that grows leaks how many are in use. A fixed pool keeps
# both constant. Unused slots are inert: with mutableUsers = false and no
# password declared here, every one of these accounts gets `!` in /etc/shadow,
# none is in wheel, and none has an authorized key, so an un-added slot cannot
# be logged into at all. It is a reserved number and a directory, nothing more.
#
# ANONCTL ADOPTS WHAT IT FINDS, which is what makes this work rather than fight:
# "Provisioning each account is a no-op if it already exists, so re-running add
# is a clean no-op" (anoncore/provision/provision.go:136). It checks each account
# and creates only what is absent, and it DISCOVERS the uid rather than assuming
# one. So `anonctl add 01` on a box carrying these declarations skips creation
# and goes straight to forcing.
#
# DECLARE BOTH HALVES OF A SLOT. provision.go:145 calls a login account that
# exists with no shim a state "the operator has to clean up by hand", so this
# module always emits the pair and never lets a host declare half of one.
#
# SHELLS ARE DECLARED AS PACKAGES, WHICH IS HOW THEY BECOME STABLE ALIASES.
# NixOS's `toShellPath` renders a `shellPackage` as `/run/current-system/sw` plus
# the package's own `shellPath`, so `pkgs.bashInteractive` becomes
# `/run/current-system/sw/bin/bash` and `pkgs.shadow` becomes
# `/run/current-system/sw/bin/nologin`. That is the GC-safe form: a literal
# `/nix/store/<hash>-bash-.../bin/bash` in /etc/passwd is correct until the next
# rebuild collects it, the same time bomb anonctl records for unit ExecStart
# paths in its own repo's
# work/notes/observations/resolved-unit-binaries-can-bake-a-nix-store-path-from-path.md.
# Writing the alias as a bare string would work too, but the package form is
# type-checked (`shellPackage`) where a string is not, so a typo fails the build
# rather than producing an account with a shell that is not there. anonctl's
# docs/nixos.md recommends exactly this form.
#
# A DEDICATED GROUP PER ACCOUNT, rather than the shared `users`. This is the one
# place where matching what `useradd` would have done is WORSE than improving on
# it: NixOS sets GROUP=100, so an account anonctl creates out of band lands in
# `users`, which on this box is also the operator's own group (uid 1001). Sharing
# it would make every group-readable file mutually visible between the operator
# and an account whose entire purpose is to be unlinkable to them. Declaring the
# accounts is precisely how that group is gained back, and anonctl's
# docs/nixos.md makes the same call. The gids are deliberately NOT pinned: the
# forcing matches `meta skuid` only, so the uid is the thing that must not move.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.anonAccounts;

  shimOf = account: "${account}-shim";

  # The LOGIN account: a normal, home-owning shell user, because that is what
  # anoncore creates (`useradd --create-home --shell <resolved>`) and what the
  # operator enters. No `extraGroups`: anoncore is explicit that the login
  # account is never added to wheel, since a sudo'd socket would carry a
  # different uid and escape the `meta skuid` forcing entirely.
  loginUser = account: slot:
    lib.nameValuePair account {
      uid = slot.uid;
      isNormalUser = true;
      createHome = true;
      home = "/home/${account}";
      homeMode = "700";
      group = account;
      shell = pkgs.bashInteractive;
      # No password, stated rather than left implicit. The account is entered
      # with `anonctl use` or `sudo -iu <account>`, both of which change uid
      # without one, so a password would be one more secret to hold and would
      # make the account no more private.
      hashedPassword = null;
      description = "anonctl anon slot ${account} (purpose deliberately unnamed)";
    };

  # The SHIM service account: the dedicated uid the per-account SOCKS relay runs
  # as, and the ONLY uid later permitted to dial the upstream endpoint. It never
  # logs in and owns no files, so it gets no home and no interactive shell.
  shimUser = account: slot:
    lib.nameValuePair (shimOf account) {
      uid = slot.shimUid;
      isSystemUser = true;
      group = shimOf account;
      home = "/var/empty";
      createHome = false;
      shell = pkgs.shadow;
      description = "anonctl shim service account for ${account}";
    };

  allUids = lib.concatMap (s: [s.uid s.shimUid]) (lib.attrValues cfg.accounts);
  allGroups = lib.concatMap (a: [a (shimOf a)]) (lib.attrNames cfg.accounts);
in {
  options.nixos-modules.anonAccounts = {
    enable = lib.mkEnableOption ''
      declared, uid-pinned passwd slots for anonctl's anon accounts.

      Required on any host with `users.mutableUsers = false`, where NixOS would
      otherwise delete anonctl's out-of-band accounts at every activation and
      leave orphaned nftables tables naming freed UIDs. Declares users only:
      anonctl still installs and owns the forcing
    '';

    accounts = lib.mkOption {
      default = {};
      example = lib.literalExpression ''
        {
          "anon" = { uid = 1101; shimUid = 441; };
          "anon-01" = { uid = 1102; shimUid = 442; };
        }
      '';
      description = ''
        The pool of anon slots, keyed by anonctl ACCOUNT NAME (`anon` is
        anoncore's default account; further slots are `anon-<slot>`). Each entry
        emits two passwd entries: the login account and its `<account>-shim`.

        The key is a SLOT ID and must never describe the identity's purpose: it
        lands in world-readable /etc/passwd, in the world-readable NixOS
        users-groups.json, in a home directory name, in a systemd unit name and
        in this repo's git history. See the module header for why no
        secret-management tool can change that.

        Declare the whole pool at once rather than growing it, so neither git
        history nor the live passwd file reveals when a slot started being used.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          uid = lib.mkOption {
            type = lib.types.ints.between 1000 29999;
            description = ''
              Pinned uid of the LOGIN account. NixOS requires >= 1000 for a
              normal user and auto-allocates normal uids UPWARD from 1000, so
              pick HIGH to stay clear of that front.

              Pinning is the security-load-bearing part, not tidiness:
              anonctl's rules match `meta skuid <uid>`, so a uid that drifts
              leaves the forcing governing an account that is no longer this
              one.
            '';
          };
          shimUid = lib.mkOption {
            type = lib.types.ints.between 400 999;
            description = ''
              Pinned uid of the SHIM service account, inside NixOS's system
              range (400-999). NixOS auto-allocates system uids DOWNWARD from
              999, so pick LOW to stay clear of that front. A declared uid is
              excluded from auto-allocation, so it can never be handed out.
            '';
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    users.users =
      lib.listToAttrs (lib.mapAttrsToList loginUser cfg.accounts)
      // lib.listToAttrs (lib.mapAttrsToList shimUser cfg.accounts);

    # One group per account, so neither half shares the operator's `users`.
    users.groups = lib.genAttrs allGroups (_: {});

    assertions = [
      {
        assertion = lib.all (n: n == "anon" || lib.hasPrefix "anon-" n) (lib.attrNames cfg.accounts);
        message = ''
          nixos-modules.anonAccounts.accounts: every key must be an anonctl account name,
          so either "anon" or "anon-<slot>". anoncore derives the passwd names
          from exactly this string, so a key it would not produce yields a
          declared account that anonctl can never adopt.
        '';
      }
      {
        # UNDERSCORES ARE REFUSED BECAUSE nft's NAMESPACE COLLAPSES THEM ONTO
        # DASHES. anonctl names each account's table `anonctl_<account>` with '-'
        # replaced by '_', since nft identifiers cannot contain a dash, so
        # `anon-a_b` and `anon-a-b` would share ONE table: adding the second
        # would silently replace the first account's forcing rules, and any
        # reader asking the kernel whether an account is jailed (reconcile's
        # forced gate does exactly that) would get the other account's answer.
        # Refusing the ambiguity at eval keeps that mapping injective by
        # construction rather than by everyone remembering.
        assertion = lib.all (n: builtins.match "anon(-[a-z0-9]+)*" n != null) (lib.attrNames cfg.accounts);
        message = ''
          nixos-modules.anonAccounts.accounts: a slot name must be "anon" or
          "anon-<part>[-<part>...]" using only lowercase letters and digits
          (offending: ${lib.concatStringsSep ", " (lib.filter (n: builtins.match "anon(-[a-z0-9]+)*" n == null) (lib.attrNames cfg.accounts))}).

          An UNDERSCORE is the one that matters: anonctl names each account's
          nftables table `anonctl_<account>` with '-' replaced by '_' (nft
          identifiers cannot contain a dash), so "anon-a_b" and "anon-a-b" would
          collide on a single table, and one account's forcing would silently
          replace the other's.
        '';
      }
      {
        assertion = lib.all (n: !(lib.hasSuffix "-shim" n)) (lib.attrNames cfg.accounts);
        message = ''
          nixos-modules.anonAccounts.accounts: name the LOGIN account only. The
          "<account>-shim" half is emitted automatically, and declaring it by
          hand would produce "<account>-shim-shim".
        '';
      }
      {
        assertion = lib.length (lib.unique allUids) == lib.length allUids;
        message = ''
          nixos-modules.anonAccounts.accounts: two slots share a uid. Every login and shim
          uid must be distinct, because the uid IS the identity anonctl's
          `meta skuid` rules are written against: a collision would force two
          accounts through one jail.
        '';
      }
    ];
  };
}
