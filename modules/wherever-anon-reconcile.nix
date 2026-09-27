# modules/wherever-anon-reconcile.nix
#
# THE WIRING that makes `anonctl add` the only verb: a boot-time oneshot plus a
# `.path` unit watching anonctl's own directories, both running the reconcile core
# (packages/anon-reconcile.nix, source in scripts/anon-reconcile.sh). It is
# `work/tasks/backlog/anon-ledger-reconcile-wiring.md` built, and it replaces
# scripts/anon-provision.sh, which did the same work by hand for one named account
# and is deleted.
#
# NOTHING HERE IS PER-ACCOUNT, and that is the property rather than a happy
# accident. One unit, one path unit, one wrapper, all named after the machinery
# and none after a slot, so adding an account re-evaluates no Nix and touches no
# repo file (spec story 15). The reconcile script discovers which slots exist by
# asking systemd for the declared `wherever-anon-*.socket` units, so even the slot
# POOL does not appear here.
#
# TWO DIRECTORIES ARE WATCHED, AND THE SECOND ONE IS NOT DECORATION.
#
#   /etc/anonctl/accounts   the LEDGER: one record per account anonctl manages.
#                           It changes on `anonctl add` and `anonctl rm`, which is
#                           the add/remove trigger.
#   /etc/anonctl            the MARKERS: one record per account anonctl has PROVEN
#                           anonymized, written only after `verify` passes and
#                           removed on `rm`.
#
# Watching only the ledger would make the gate in ADR-0019 operationally painful:
# an account added while its endpoint was down is managed but not yet proven, so
# reconcile refuses it, and nothing would ever re-run when `anonctl verify` later
# went green. Watching the marker directory closes that loop, so the interface
# appears by itself the moment the jail is provable, with no operator command. In
# the ordinary case both land inside one `anonctl add` (it runs verify inline and
# writes the marker on green), so `add` really is the only verb.
#
# A `.path` unit watches a directory that does not exist yet by watching its
# ancestors, so a box where `anonctl add` has never run (every freshly born
# machine, spec story 1) is a supported, inert state rather than a failure.
#
# ORDERING AFTER anonctl-nftables.service IS LOAD-BEARING AT BOOT. The forced gate
# asks the KERNEL whether the account's rules are loaded right now, so running
# before anonctl's own boot-time loader would see no rules and retract every anon
# route. Read the other way round, that is the property this buys: if anonctl's
# ruleset ever fails to load, reconcile retracts the routing instead of serving
# interfaces whose sessions are no longer jailed.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.whereverAnon;
  rcfg = cfg.reconcile;
  proxy = config.nixos-modules.anonDispatcher;

  # The whole invocation, built once and used in both places it is needed: the
  # unit and the operator's command. Two copies would be two things to keep in
  # step, and the operator's copy is the one nobody would notice had drifted.
  #
  # SPELLED OUT IN THE UNIT'S ExecStart rather than hidden inside the wrapper,
  # for two reasons. `systemctl cat wherever-anon-reconcile` then shows every
  # location this machinery touches, which is what an operator debugging it
  # actually wants; and the flake's genericity check can READ the argv, so
  # "reconcile names no account and no colorway" and "it reads the same routes
  # directory the dispatcher imports" become evaluated claims rather than
  # intentions.
  args = lib.escapeShellArgs [
    "--ledger-dir"
    rcfg.ledgerDir
    "--marker-dir"
    rcfg.markerDir
    "--state-dir"
    cfg.stateRoot
    "--routes-dir"
    rcfg.routesDir
    "--routes-group"
    cfg.proxyGroup
    "--socket-root"
    cfg.socketRoot
    "--palette"
    cfg.palettePath
    "--domain"
    rcfg.domain
    "--link-scheme"
    "http"
    "--link-port"
    (toString proxy.port)
    # THE FORCED GATE, as a store path rather than a PATH lookup: the binary that
    # decides whether an account is jailed is then the same build this host
    # declares and deploys, covered by a rebuild and a rollback like everything
    # else. `anonctl probe` needs 0.7.0 or newer; an older binary has no such verb
    # and every account is refused with `probe-unusable`, which is loud and
    # fail-closed rather than silently permissive.
    "--anonctl"
    (lib.getExe rcfg.anonctlPackage)
  ];
  # NOTE what is NOT passed: the caddy BINARY and the caddy CONFIG. Both are read
  # off the running caddy unit's own ExecStart at runtime, which is stronger than
  # anything this module could declare: the validator is then by construction the
  # same binary, with the same config, that will have to load the fragment. A
  # hardcoded /etc/caddy/caddy_config would be this module guessing at another
  # module's internals, and the day it drifted, `adapt` would fail on a file that
  # has nothing to do with any account while the script read that as "this
  # fragment is bad".

  # `anon-reconcile` as the operator sees it: the same store path with this
  # host's locations already filled in, so `sudo anon-reconcile links` is one
  # command rather than eight arguments nobody will remember.
  hostReconcile = pkgs.writeShellScriptBin "anon-reconcile" ''
    exec ${lib.getExe rcfg.package} ${args} "$@"
  '';
in {
  options.nixos-modules.whereverAnon.reconcile = {
    enable = lib.mkEnableOption ''
      the reconcile oneshot and its path unit, which turn anonctl's ledger into
      per-account wherever-anon state and Caddy routing automatically.

      With this on, `anonctl add <name>` is the only verb: the ledger record (and
      the marker `add` writes when its inline verify passes) trigger reconcile,
      which mints a handle, a token and a colorway, writes the account's state and
      its routing fragment, and starts the instance's socket. `anonctl rm <name>`
      removes all of it again, disturbing no other account
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.anon-reconcile;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.anon-reconcile";
      description = ''
        The reconcile core. Takes every location and every external command as an
        argument, which is what makes it fixture-testable without root; this
        module supplies this host's locations.
      '';
    };

    anonctlPackage = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.anonctl;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.anonctl";
      description = ''
        The anonctl build whose `probe` verb IS the forced gate. Defaults to the
        same package the host installs, so reconcile and the operator cannot be
        asking two different binaries whether an account is jailed.

        Needs 0.7.0+, which added `probe`. Before it, this script asked the kernel
        itself by grepping the account's nft table for `skuid <uid>`, which was
        both a coupling to anonctl's private table naming AND wrong: it matched
        the uid anywhere in the table, so a table that was loaded but did not
        FUNNEL that uid into the fail-closed chain read as jailed. Measured on
        this box against 0.7.0's own generated ruleset in a network namespace:
        remove the single `meta skuid <uid> jump anon_filter` line and the grep
        still says jailed, while probe says `uid-not-governed`.
      '';
    };

    ledgerDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/anonctl/accounts";
      description = ''
        anonctl's LEDGER: one `<account>.json` per account it manages, mode 0700
        with 0600 files. THE seam, and the only coupling to anonctl there will
        ever be.

        Reconcile reads the FILENAMES and never the contents: their shape is
        anonctl's business, and guessing it is how you build something that works
        on one box and silently misreads another.

        STILL NOT `anonctl list --json`, but the reason has MOVED and the old one
        must not be repeated: as of anonctl 0.7.0 that command is honest. It no
        longer carries the `forced` zero value at all, forcing is an explicit
        tri-state, and a new `managed` field distinguishes a declared-but-never-
        added slot from one anonctl actually manages, which was the specific trap
        this fleet fell into (the whole anon pool is declared here, so every slot
        is in passwd from the first converge). Reading `list` today would be
        correct. The 0.6.x hazard is recorded, with its resolution, in
        work/notes/findings/anonctl-list-enumerates-passwd-and-its-forced-field-is-a-zero-value.md

        What keeps the DIRECTORY as the seam is a different property: this is an
        inotify watcher, not a poller. `.path` units watch paths, so the thing
        reconcile is triggered BY and the thing it enumerates should be the same
        thing, or the two can disagree about what just happened. A ledger file
        appearing IS the add event; asking a command afterwards is a second
        reading of a world that may have moved again. Filenames also stay the
        narrowest possible dependency: no output shape to version, nothing to
        re-verify when anonctl changes a field, and no process spawned per
        trigger.
      '';
    };

    markerDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/anonctl";
      description = ''
        anonctl's MARKER directory: one `<account>.json` per account it has PROVEN
        anonymized. anonctl writes a marker strictly after `verify` passes and
        removes it on `rm`.

        WATCHED, not read for gating. Whether an account is jailed is `anonctl
        probe`'s answer (ADR-0019); this directory is here because it is half the
        TRIGGER surface, and watching it is what makes a later `anonctl verify`
        going green provision the interface with no operator command.
      '';
    };

    routesDir = lib.mkOption {
      type = lib.types.str;
      default = proxy.routesDir;
      defaultText = lib.literalExpression "config.nixos-modules.anonDispatcher.routesDir";
      description = ''
        Where the routing fragments land. Read from the dispatcher rather than
        restated, so the writer and the glob-importing reader cannot disagree.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = proxy.domain;
      defaultText = lib.literalExpression "config.nixos-modules.anonDispatcher.domain";
      description = ''
        The domain the wildcard site serves, so a handle becomes
        `<handle>.<domain>`. Read from the reverse proxy for the same reason as
        routesDir.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && rcfg.enable) {
    assertions = [
      {
        assertion = proxy.enable;
        message = ''
          nixos-modules.whereverAnon.reconcile.enable is on but the anon dispatcher is
          not (nixos-modules.anonDispatcher.enable). Reconcile would write
          routing fragments into a directory nothing imports, so every provisioned
          interface would be unreachable while looking perfectly healthy.
        '';
      }
      {
        assertion = rcfg.domain != "";
        message = ''
          nixos-modules.whereverAnon.reconcile needs a domain: it is what turns an
          opaque handle into the URL the operator opens. Set
          nixos-modules.anonDispatcher.domain (which it follows by default).
        '';
      }
    ];

    # The operator's half of the contract. The token is 0400-ish state owned by
    # the account and is never printed by reconcile itself, so retrieving a link
    # needs a command: `sudo anon-reconcile links`. It is root-only in effect
    # rather than by permission, because the state files it reads are 0600 and
    # account-owned; a non-root caller simply sees nothing, which is the right
    # failure.
    environment.systemPackages = [hostReconcile];

    systemd.services.wherever-anon-reconcile = {
      description = "Reconcile anonctl's ledger into wherever-anon state and Caddy routing";

      # BOOT-TIME RESTORE (story 9). Everything reconcile writes survives a reboot
      # on its own (state in /var/lib, fragments in /etc/caddy, and Caddy reads
      # those at start), so this is not what makes the interfaces come back. What
      # it does is re-check the forced gate against the ruleset that was just
      # loaded, and retract anything that is no longer provable.
      wantedBy = ["multi-user.target"];

      after = [
        # The kernel truth the gate asks for. Without this ordering a boot-time
        # run would see no rules yet and retract every route.
        "anonctl-nftables.service"
        # So the reload at the end has something to reload, and so the fragments
        # are on disk before Caddy adapts them.
        "caddy.service"
        "network.target"
      ];

      # NO `requires` and NO `wants`: a box with no anonctl at all, or with
      # anonctl installed and never used, must be inert rather than failed.
      # NO START RATE LIMIT, and this is the difference between working
      # automation and automation that silently switches itself off. systemd's
      # default is 5 starts per 10s, and systemd.path(5) is explicit that when a
      # triggered service hits its start limit, "the error condition ... is
      # propagated from the service unit to the path unit and causes the path
      # unit to fail as well": the watch STOPS, and from then on `anonctl add`
      # produces nothing at all, with no journal line at add time, until someone
      # restarts the .path by hand.
      #
      # That is reachable here rather than theoretical: every `anonctl add`
      # produces two watched events (the ledger record, then the marker its
      # inline verify writes), a run takes about a second, and FAILED starts
      # count too while this unit exits 3 on every refusal BY DESIGN. Rate
      # limiting buys nothing in exchange: the script is idempotent and
      # serialized by its own flock. Same treatment, for the same reason, as
      # modules/scanning.nix and modules/printing.nix.
      unitConfig.StartLimitIntervalSec = 0;

      serviceConfig = {
        Type = "oneshot";
        # Longer than the script's own 60s lock wait, so a run blocked behind
        # another one dies with ITS message rather than being killed here first
        # and reported as a generic timeout.
        TimeoutStartSec = 300;
        # Runs as ROOT, necessarily and on purpose: it writes state owned by each
        # anon account, reads anonctl's 0700 ledger and marker directories, asks
        # the kernel for the live ruleset, and drives systemctl.
        ExecStart = "${lib.getExe rcfg.package} ${args} reconcile";
        # A refusal (exit 3) is a real failure and must show in `systemctl
        # --failed`: a managed account that never got an interface looks exactly
        # like a bug, so it must not scroll past in the journal.
        RemainAfterExit = false;
        # It talks to systemd and to the kernel's nft tables, so the usual
        # sandboxing knobs are mostly unavailable. The two that cost nothing:
        PrivateTmp = true;
        ProtectHome = true;
      };
    };

    # THE PERIODIC RE-CHECK, which is what makes ADR-0019's claim CONTINUOUS
    # rather than point-in-time. The path unit fires on anonctl's files, and the
    # oneshot runs at boot; neither notices the KERNEL changing. A `nft flush
    # ruleset`, an anonctl reload that failed, or the firewall interaction this
    # spec names as its one unproven risk would remove an account's forcing
    # while its fragment stays on disk, its socket stays active and its dashboard
    # stays up, with sessions egressing in the clear behind an interface that
    # still looks anonymised, indefinitely and silently.
    #
    # It also repairs the other direction: when the refusal reason WAS the
    # ruleset, fixing it touches nothing under /etc/anonctl, so without this the
    # interface would stay retracted with nothing left to trigger its return.
    #
    # An unchanged run is genuinely cheap: a few file reads, one `nft list table`
    # per managed account, and NO `caddy adapt` at all (the fragment comparison
    # returns before validating when the content already matches), so nothing is
    # written and no reload happens.
    systemd.timers.wherever-anon-reconcile = {
      description = "Re-check periodically that every provisioned anon interface is still jailed";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "10min";
        AccuracySec = "1min";
        Unit = "wherever-anon-reconcile.service";
      };
    };

    systemd.paths.wherever-anon-reconcile = {
      description = "Watch anonctl's ledger and markers, and reconcile when they change";
      wantedBy = ["multi-user.target"];
      # The path unit has its own TriggerLimit (200 per 2s) which is not at issue;
      # what would disarm it is the SERVICE's start limit propagating here, which
      # is turned off above. Mirrored anyway so neither unit carries a rate limit
      # that can switch the automation off.
      unitConfig.StartLimitIntervalSec = 0;
      pathConfig = {
        # PathChanged on a DIRECTORY fires when an entry is created or removed,
        # which is exactly `anonctl add`, `anonctl rm` and `anonctl verify`
        # writing a marker. Both may be absent on a fresh box: systemd then
        # watches the closest existing ancestor and starts working the moment they
        # appear.
        PathChanged = [rcfg.ledgerDir rcfg.markerDir];
        # The triggered unit is the same-named .service by default; named
        # explicitly because this pairing is the whole mechanism.
        Unit = "wherever-anon-reconcile.service";
      };
    };
  };
}
