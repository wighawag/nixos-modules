# modules/wherever-anon.nix
#
# A wherever instance per anon account, RUNNING AS THAT ACCOUNT'S OWN LOGIN UID
# and serving over a unix socket that Caddy reaches with `reverse_proxy
# unix/<path>`. This is `work/tasks/backlog/wherever-anon-instance-unit.md`
# built, and it is the sibling of modules/anon-search.nix: both are per-account
# daemons running as the account, and they answer every shared question the same
# way on purpose.
#
# WHY AS THE ACCOUNT'S UID. anonctl's forcing rules match `meta skuid <uid>`, so
# a daemon under the account's uid is forced by exactly the same kernel rules as
# the account's interactive shell. That matters more here than for search,
# because wherever hosts agent sessions IN-PROCESS: there is no `pi` child, so a
# session's uid IS the server's uid. Run this as anything else and the sessions
# are not jailed at all, which is the entire feature gone while everything still
# looks healthy.
#
# A UNIX SOCKET IS NOT A STYLE CHOICE, AND IT COST AN UPSTREAM FEATURE. An anon
# account CANNOT SERVE A LOOPBACK TCP PORT AT ALL: anonctl's closure ends in
# `meta skuid <anon> ip daddr 127.0.0.0/8 drop`, and an inbound connection's
# REPLY packets carry the LISTENING socket owner's uid, so the SYN arrives
# (there is no input chain) and the SYN-ACK is dropped. The handshake never
# completes. A loopback exemption does NOT rescue it: anonctl's exemption clause
# is a single `tcp dport` match and the reply direction's dport is an ephemeral
# port no exemption can name. Measured, along with a unix-socket control that
# counted zero packets on any rule:
# work/notes/findings/anon-uid-cannot-serve-inbound-tcp-the-reply-is-dropped.md
#
# The task that specified this was written before that was known, and wherever
# could not satisfy it either: through 0.15.2 the only listen call in the server
# was `server.listen(port, host, cb)`, with no `--socket`, no LISTEN_FDS handling
# and no `{fd:}` listen anywhere. So the feature was added UPSTREAM (wherever
# 0.16.0) rather than worked around here, and this module is its first consumer.
#
# `--socket fd://3`, NOT `--socket <path>`, AND THE REASON IS CROSS-UID. Both
# forms exist upstream. The path form makes the server create the socket, so the
# socket is owned by whoever the server already is, and reaching it from Caddy
# (a DIFFERENT uid) would need a shared supplementary group and a 0750 parent
# directory: the same dance modules/searxng.nix does for the operator's
# instance. The fd form lets systemd create, bind, chown and chmod the socket AS
# ROOT before this process exists, so `SocketUser`/`SocketGroup`/`SocketMode`
# below place a correctly-owned socket directly. anon-search could skip all of
# this because its consumer was the SAME uid (0600 plus ownership sufficed);
# here the consumer is Caddy, so the socket is 0660 account:caddy and only the
# supervisor could have made it so.
#
# ONE INSTANCE PER DECLARED SLOT, exactly as modules/anon-search.nix does, and
# for the same privacy reason rather than for tidiness. The instance set does
# NOT follow which accounts are actually forced: that would need an explicit
# list in the host file (anonctl's ledger is imperative state Nix cannot read),
# and such a list would record WHICH SLOTS ARE IN USE AND WHEN EACH BECAME SO,
# IN GIT HISTORY, which is the timing leak modules/anon-accounts.nix declares its
# whole pool at once to avoid. Socket activation is what makes that free: an
# unused instance is a socket inode and no node process.
#
# DECLARED VERSUS OBSERVED IS THE RULE, not name-versus-no-name. A slot name MAY
# appear in evaluated output and in store paths, because the pool is declared in
# full from the first commit so a slot's existence reveals nothing; ADR-0017
# ruled this explicitly and modules/anon-accounts.nix, modules/anon-home.nix and
# modules/anon-search.nix all rely on it. What must NEVER reach evaluated output
# is anything revealing WHICH slots are in use, WHEN, or BY WHOM: the handle, the
# token, the COLORWAY ASSIGNMENT and any socket path drawn from live state. Note
# the asymmetry: the palette is declared and generic, so palette entry NAMES are
# fine in the store, while the mapping from a slot to its colorway is observed
# state and is not. That is why the palette is a store file and the assignment is
# a runtime read. Older drafts of the task and the spec describe a `%i` TEMPLATE
# unit; that mechanism is superseded (it pushes the name into runtime state, so
# nothing can be checked at eval time) while its reasoning is kept whole.
#
# PRIVATETMP IS LOAD-BEARING FOR PRIVACY HERE TOO, and for a STRONGER reason
# than in anon-search. There the shared path was SearXNG's fixed-name /tmp cache,
# which collided. Here it is a READ channel exposed over HTTP: wherever's
# `resolveDownloadRoots` ALWAYS adds the resolved upload directory to the set of
# roots `/session/download` will serve from, and `resolveUploadDir` defaults to
# `os.tmpdir()`. So with the default upload config a shared /tmp makes every
# readable file under /tmp fetchable by whoever holds that instance's token,
# including other slots' uploads (written `<timestamp>_<filename>`, mode 0644)
# and anything the operator left there. Verified by reading the pinned server
# source, not assumed. A private /tmp makes each instance's upload dir and
# download root its own, which is both the fix and the right lifetime for an
# anon session's scratch files.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.whereverAnon;
  anonHome = config.nixos-modules.anonHome;

  # The declared palette, as ONE store file for every account. It is generic by
  # construction (names and colours, no assignment), so it is exactly the kind
  # of thing that belongs in the store. Exposed through `palettePath` because
  # anon-ledger-reconcile-core has to read the SAME palette to assign from it: a
  # palette only this module could see would force that task to guess.
  paletteFile = pkgs.writeText "wherever-anon-colorways.json" (builtins.toJSON cfg.colorways);

  # ONE start script for every account, not one per slot, because nothing in it
  # is per-account: the socket arrives as fd 3, and the paths come from the
  # environment the unit sets. Keeping it shared also keeps slot names out of one
  # more store path, which costs nothing and is the habit this fleet wants.
  startScript = pkgs.writeShellScript "wherever-anon-start" ''
    set -euo pipefail

    jq=${pkgs.jq}/bin/jq

    # THE OBSERVED STATE. Written by anon-ledger-reconcile-core, never by Nix.
    # Four fields, and this is the contract that task is written against:
    #
    #   { "socketPath": "/run/wherever-anon/<account>/wherever.sock",
    #     "token":      "<opaque secret>",
    #     "handle":     "<opaque random URL label>",
    #     "colorway":   "<a NAME from the declared palette>" }
    #
    # It used to say PORT rather than socketPath; that changed when serving a
    # port turned out to be impossible for an anon uid (see the header).
    if [ ! -r "$WA_STATE_FILE" ]; then
      echo "FATAL: no readable state at $WA_STATE_FILE." >&2
      echo "  An instance is only meaningful once reconcile has provisioned the slot:" >&2
      echo "  the token, handle and colorway are OBSERVED state and cannot come from the repo." >&2
      exit 1
    fi

    token="$("$jq" -r '.token // ""' "$WA_STATE_FILE")"

    # THE TOKEN IS REQUIRED UNCONDITIONALLY, and this refusal is the point.
    # The operator's own instance can lean on mesh-only reachability for access
    # control; an anon instance cannot make that assumption and must demand its
    # own token even inside the mesh. Refusing to START is what makes that a
    # property rather than a default: an instance that came up unauthenticated
    # because a secret had not rendered would look completely healthy.
    if [ -z "$token" ]; then
      echo "FATAL: $WA_STATE_FILE carries no token." >&2
      echo "  An anon instance must not run unauthenticated: it is reachable through the" >&2
      echo "  wildcard Caddy site, and anyone who reached it would have full agent and" >&2
      echo "  filesystem access AS this jailed identity. Refusing to start." >&2
      exit 1
    fi

    # The socket path is DECLARED (it has to be: ListenStream is evaluated), and
    # the state records it so reconcile can write the Caddy fragment without
    # re-deriving the convention. Two places, so check they agree rather than
    # letting Caddy proxy to a socket nothing serves.
    stateSocket="$("$jq" -r '.socketPath // ""' "$WA_STATE_FILE")"
    if [ -n "$stateSocket" ] && [ "$stateSocket" != "$WA_SOCKET_PATH" ]; then
      echo "FATAL: state names socket $stateSocket but this unit serves $WA_SOCKET_PATH." >&2
      exit 1
    fi

    # The handle is the opaque URL label the dispatcher routes on. This unit does
    # not need it (it serves a socket, not a name), but an empty one means the
    # instance is unroutable, which is worth saying once here rather than
    # debugging from a 404 later. Not fatal: the socket still serves.
    if [ -z "$("$jq" -r '.handle // ""' "$WA_STATE_FILE")" ]; then
      echo "[wherever-anon] WARNING: state carries no handle, so nothing can route to this instance." >&2
    fi

    colorway="$("$jq" -r '.colorway // ""' "$WA_STATE_FILE")"
    if [ -z "$colorway" ]; then
      # Never empty, because wherever's own fallback is os.hostname(), which
      # would label every instance on this box `telemaque` and make them
      # indistinguishable: the exact opposite of why a colorway exists.
      echo "[wherever-anon] WARNING: state names no colorway; labelling this instance 'anon'." >&2
      colorway="anon"
    fi

    # A colorway that is not in the palette must still yield a RUNNING instance.
    # A missing colour is cosmetic and must never cost the operator their
    # interface. Substituting a DIFFERENT palette entry would be worse than
    # defaulting, because two accounts would then share a colour and the whole
    # distinguishing property dies quietly.
    look="$("$jq" -c --arg n "$colorway" '.[$n] // empty' ${paletteFile})"
    if [ -z "$look" ]; then
      echo "[wherever-anon] colorway '$colorway' is not in the declared palette; using the default look." >&2
      look='{}'
    fi

    # The rendered config, into a per-instance /run dir. It is built from
    # NOTHING but the palette and this account's own state, so there is no path
    # by which an operator credential could reach it. `label` is the COLORWAY'S
    # NAME: never the account name (local-visible by design, but with no business
    # in a browser window that can be screenshotted or shoulder-surfed) and never
    # the handle (already in the URL).
    "$jq" -n --arg label "$colorway" --argjson look "$look" \
      '{appearance: ($look + {label: $label})}' > "$WA_CONFIG_DIR/config.json"

    # The token as a FILE, never on argv: /proc/<pid>/cmdline is world-readable,
    # so `--token` would hand this identity's secret to every local user via
    # `ps`. Same reasoning as modules/wherever.nix's WHEREVER_TOKEN_FILE.
    ( umask 077; printf '%s' "$token" > "$WA_CONFIG_DIR/token" )

    export WHEREVER_TOKEN_FILE="$WA_CONFIG_DIR/token"
    export WHEREVER_CONFIG_DIR="$WA_CONFIG_DIR"

    # `exec` matters: it preserves the PID (so LISTEN_PID still names us) and
    # fd 3 (the socket itself), neither of which survives a forked child.
    exec ${cfg.package}/bin/wherever start --socket fd://3 --no-ssl
  '';

  unitNameFor = account: "wherever-anon-${account}";
in {
  options.nixos-modules.whereverAnon = {
    enable = lib.mkEnableOption ''
      a wherever instance per anon account, each running as that account's own
      uid and serving over a unix socket that Caddy reverse-proxies.

      Needs nixos-modules.anonHome on the same host: that is what declares the accounts and
      places the credential-free home content (models.json, webveil.json) the
      sessions inside these instances depend on
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.wherever;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.wherever";
      description = ''
        The wherever build to run. Must be 0.16.0 or newer: that is the release
        that added unix socket support, and an anon account cannot serve a TCP
        port at all, so an older build has no reachable interface whatsoever.
        An assertion below refuses one.
      '';
    };

    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = anonHome.accounts;
      defaultText = lib.literalExpression "config.nixos-modules.anonHome.accounts";
      description = ''
        Which anon accounts get an instance. DERIVED from nixos-modules.anonHome, which is
        itself derived from nixos-modules.anonAccounts, so the instance set follows the
        DECLARED POOL and never a list of who is actually using a slot.

        That is a privacy property rather than a convenience: a list of active
        accounts would have to live in the host file, and it would record which
        slots are in use and when each became so, in git history. Socket
        activation is what makes declaring all of them free.
      '';
    };

    proxyGroup = lib.mkOption {
      type = lib.types.str;
      default = config.services.caddy.group;
      defaultText = lib.literalExpression "config.services.caddy.group";
      description = ''
        The group that may CONNECT to these sockets, i.e. the group the reverse
        proxy runs as. It owns the socket's group and is what makes the 0660
        mode meaningful.

        This is the one place this module is less locked-down than
        modules/anon-search.nix, and deliberately so: there the consumer was the
        same uid as the server, so ownership alone was the access control and the
        socket could be 0600. Here the consumer is Caddy, running as a different
        uid, so something has to bridge them. A group on a socket systemd creates
        as root is the narrowest way to do it: no supplementary group is added to
        any account, and nothing else in the account's world changes.
      '';
    };

    colorways = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          accent = lib.mkOption {
            type = lib.types.str;
            description = "The accent colour, as a CSS colour wherever retints its brand family from.";
          };
          pattern = lib.mkOption {
            type = lib.types.enum ["stripes" "dots" "grid" "none"];
            description = "The backdrop pattern, from wherever's supported set.";
          };
          colors = lib.mkOption {
            type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
            default = null;
            description = "An optional full palette override, passed through untouched.";
          };
        };
      });
      default = {
        amber = {
          accent = "#d97706";
          pattern = "stripes";
        };
        teal = {
          accent = "#0d9488";
          pattern = "dots";
        };
        violet = {
          accent = "#7c3aed";
          pattern = "grid";
        };
        crimson = {
          accent = "#dc2626";
          pattern = "dots";
        };
        slate = {
          accent = "#475569";
          pattern = "stripes";
        };
      };
      description = ''
        The declared colorway palette, keyed by a STABLE NAME. Each entry is an
        accent plus a pattern (and optionally a full `colors` override), which
        wherever's own `appearance` block consumes natively.

        KEYED BY NAME RATHER THAN BY INDEX so that re-ordering or extending the
        palette is safe: an account's state stores only the NAME, never the
        resolved colour, which keeps that state minimal and lets the palette be
        re-tuned here without rewriting live per-account state.

        WHOLLY GENERIC, WHICH IS WHY IT LIVES IN THE REPO. A palette entry name
        in a store path reveals nothing; the mapping from a slot to its colorway
        is observed state and stays on the box. That asymmetry is the whole
        reason the palette is declared here and the assignment is read at
        runtime, and the eval-level genericity check has to respect it.

        The NAME is what a human says out loud to tell two instances apart, and
        it is what gets rendered as wherever's `appearance.label`. It is
        deliberately not the account name and not the handle.
      '';
    };

    socketRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/wherever-anon";
      description = ''
        READ-ONLY: the directory every slot's socket lives under. Exposed so that
        reconcile (modules/wherever-anon-reconcile.nix) can be told where the
        sockets are without restating the convention, which is the only way the
        writer of the routing fragments and the unit that serves them cannot
        drift apart.
      '';
    };

    stateRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/wherever-anon";
      description = ''
        READ-ONLY: the directory every slot's observed state lives under, for the
        same reason as socketRoot. Nothing in Nix ever reads its CONTENT.
      '';
    };

    socketPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.genAttrs cfg.accounts (a: "${cfg.socketRoot}/${a}/wherever.sock");
      defaultText = lib.literalExpression ''lib.genAttrs cfg.accounts (a: "''${cfg.socketRoot}/''${a}/wherever.sock")'';
      description = ''
        READ-ONLY: where each account's instance serves, as a unix socket path,
        and therefore what the Caddy dispatcher must `reverse_proxy unix/` at.
        Exposed as an attrset so this module and the dispatcher cannot disagree
        about the path; whoever routes to it reads this rather than restating it,
        exactly as nixos-modules.anonHome.webTools.searchSocketPaths does for search.

        DECLARED, not observed, and that is forced by the mechanism rather than
        chosen: `ListenStream` is evaluated at build time, so the socket unit
        cannot take its path from runtime state. The path is derived purely from
        the DECLARED slot name, so it carries no information about who is using
        the slot, which is what the genericity rule actually protects. The
        account's state records the same path for reconcile's benefit and the
        start script refuses a mismatch.

        IN /run, on a tmpfs, so a stale socket cannot outlive a reboot: cleanup
        is structural rather than dependent on RemoveOnStop catching a clean
        shutdown, which a crash or a power cut is not. And the account's home
        stays purely modules/anon-home.nix's declared content.
      '';
    };

    statePaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.genAttrs cfg.accounts (a: "${cfg.stateRoot}/${a}/state.json");
      defaultText = lib.literalExpression ''lib.genAttrs cfg.accounts (a: "''${cfg.stateRoot}/''${a}/state.json")'';
      description = ''
        READ-ONLY: where each account's OBSERVED state lives, which is the file
        anon-ledger-reconcile-core writes and this module's start script reads.
        It carries four fields: `socketPath`, `token`, `handle` and `colorway`.

        Nothing in Nix ever reads its CONTENT: this option is the path only, so
        the token, handle and colorway assignment cannot reach evaluated output
        through it.
      '';
    };

    palettePath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${paletteFile}";
      defaultText = lib.literalExpression "a store path holding the rendered colorways";
      description = ''
        READ-ONLY: the rendered palette as a store path, so that
        anon-ledger-reconcile-core can read the SAME palette this module renders
        when it assigns a colorway to a new slot. Without this the reconcile task
        would have to hardcode the names and could drift from the declaration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = anonHome.enable;
        message = ''
          nixos-modules.whereverAnon.enable is on but nixos-modules.anonHome.enable is off, so
          there are no declared anon accounts to serve and `accounts` would be
          empty. Enable nixos-modules.anonHome (which declares the home content the sessions
          inside these instances depend on) or turn this off.
        '';
      }
      {
        # 0.15.2 and older have no --socket at all: the only listen call is
        # `server.listen(port, host, cb)`. An anon account cannot serve a TCP
        # port, so an older build would produce an instance with NO reachable
        # interface: the unit would start, the socket unit would hand it fd 3,
        # and the server would ignore it and bind 127.0.0.1:31415 that nothing
        # can complete a handshake against. Fail at eval instead.
        assertion = lib.versionAtLeast cfg.package.version "0.16.0";
        message = ''
          nixos-modules.whereverAnon needs wherever 0.16.0 or newer (this is
          ${cfg.package.version}). Unix socket support (`--socket fd://<n>`)
          landed in 0.16.0, and it is not optional here: an anon account cannot
          serve a loopback TCP port at all, because anonctl's closure drops the
          reply packets, which carry the listening socket owner's uid. An older
          build would bind a port nothing can reach and look perfectly healthy.
        '';
      }
      {
        # The palette is what makes two instances distinguishable, so an empty
        # one is not a smaller feature, it is the feature absent: every instance
        # would fall to the default look and the same label.
        assertion = cfg.colorways != {};
        message = ''
          nixos-modules.whereverAnon.colorways is empty, so every instance would get
          the default look and nothing would tell two of them apart. Declare at
          least as many colorways as there are slots you expect to run at once.
        '';
      }
      {
        # Not a style rule: `label` is rendered into the dashboard chrome, and a
        # colorway named after an account would put a jailed identity's local
        # name into a window that can be screenshotted or shoulder-surfed.
        assertion = !(lib.any (n: lib.elem n cfg.accounts) (lib.attrNames cfg.colorways));
        message = ''
          nixos-modules.whereverAnon.colorways names a colorway after an anon account
          (${lib.concatStringsSep ", " (lib.filter (n: lib.elem n cfg.accounts) (lib.attrNames cfg.colorways))}).

          The colorway NAME is rendered as wherever's `appearance.label`, i.e.
          into the dashboard chrome, so it must never be an account name. Use a
          neutral, memorable name (amber, teal) that a human can say out loud to
          tell two instances apart.
        '';
      }
    ];

    # The per-account socket DIRECTORY. 0750 and account-owned, with the proxy's
    # group, because Caddy must be able to TRAVERSE it to reach the socket
    # inside. This is the one place this differs from anon-search's 0700: there
    # the only consumer was the account itself.
    #
    # Ordering is safe without stating it: systemd-tmpfiles-setup runs in
    # sysinit.target, which precedes basic.target and therefore sockets.target,
    # so these directories exist before any of these sockets binds.
    systemd.tmpfiles.rules =
      [
        "d /run/wherever-anon 0755 root root -"
        "d /var/lib/wherever-anon 0755 root root -"
      ]
      ++ lib.concatMap (account: [
        "d /run/wherever-anon/${account} 0750 ${account} ${cfg.proxyGroup} -"
        # The state directory is created here rather than left to the unit's
        # StateDirectory, because RECONCILE writes into it BEFORE the instance
        # has ever started (that is the whole point: provision, then serve).
        "d /var/lib/wherever-anon/${account} 0700 ${account} ${account} -"
      ])
      cfg.accounts;

    # THE SOCKET. systemd creates, binds, chowns and chmods it as root BEFORE
    # the service runs, which is the only way a socket owned by the account and
    # connectable by Caddy can exist without adding a supplementary group to
    # anything or making the server privileged.
    systemd.sockets = lib.listToAttrs (map (account:
      lib.nameValuePair (unitNameFor account) {
        description = "wherever socket for anon account ${account}";
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = cfg.socketPaths.${account};
          SocketUser = account;
          # The PROXY's group, not the account's: `connect()` needs write
          # permission on the socket inode, so this plus 0660 is exactly what
          # lets Caddy in and nothing else.
          SocketGroup = cfg.proxyGroup;
          SocketMode = "0660";
          # Never leave a stale socket behind. /run being a tmpfs covers the
          # crash and power-cut cases that this cannot.
          RemoveOnStop = true;
        };
      })
    cfg.accounts);

    systemd.services = lib.listToAttrs (map (account:
      lib.nameValuePair (unitNameFor account) {
        description = "wherever for anon account ${account} (runs as that account, sessions jailed by the kernel)";

        # NO `wantedBy`. Socket-activated: the unit starts on the first
        # connection and not at boot, which is what makes one instance per
        # declared slot cost a socket inode instead of a node process, and
        # therefore what lets the pool be declared uniformly.
        requires = ["${unitNameFor account}.socket"];
        after = ["${unitNameFor account}.socket" "network.target"];

        # THE BOX'S GLOBAL TOOLS ARE ON THE PATH, because PATH IS NOT A BOUNDARY.
        # Every binary under /run/current-system/sw is in the world-readable
        # store and ProtectSystem does not hide it, so a session could always
        # exec it by absolute path; leaving it off PATH only made a hosted model
        # conclude that python or node were not installed. The operator's unit
        # carries the same entry.
        #
        # WHAT ACTUALLY KEEPS A TOOL SAFE HERE is the absence of CREDENTIALS and
        # the uid, never the absence of the binary. A `gh` on the path is fine;
        # an AUTHENTICATED one is the confusion this module exists to prevent,
        # and it cannot happen: there is no EnvironmentFile (so no GH_TOKEN),
        # and ProtectHome=tmpfs means the operator's ~/.config/gh, ~/.ssh and
        # ~/.gitconfig do not exist in this unit's view (see below). Anything a
        # session runs still egresses under this account's uid, so anonctl's
        # rules force it exactly as they force the server.
        #
        # Adding the directory as a `path` entry puts ONLY
        # /run/current-system/sw/bin (and sbin) on PATH. The unit reads no
        # profile and no set-environment, so none of the operator-named entries
        # that modules/anon-home.nix scrubs from the login shell appear here.
        #
        # /run/wrappers/bin (sudo and the other setuid wrappers) is deliberately
        # NOT added: NoNewPrivileges makes every one of them fail anyway, and a
        # present-but-broken sudo only invites a session to keep trying it.
        # git, bash and coreutils stay listed explicitly so the unit does not
        # depend on the host installing them system-wide.
        #
        # WEBHANDS IS ADDED WHEN THE ANON HOME DECLARES A BROWSER, and it used to
        # be deliberately absent: an absent tool was a better failure than a
        # present one that died with SIGSYS at the first launch. That reason is
        # gone now that the syscall policy below lets Chromium start (measured;
        # see SystemCallFilter). It is the SAME store path the host installs
        # box-wide and the anon login shell runs, so the dashboard and
        # `anonctl use` drive one declared browser, not two.
        path =
          [pkgs.git pkgs.bash pkgs.coreutils "/run/current-system/sw"]
          ++ lib.optional anonHome.browser.enable anonHome.browser.package;

        environment =
          {
            # The account's OWN home, so a session finds the declared
            # models.json and webveil.json that modules/anon-home.nix placed
            # there. This unit only READS it: everything wherever writes is
            # redirected below, so the home stays purely that module's declared
            # content and nothing here drops a file into a directory it owns.
            # (A hosted session's BROWSER does write there, into ~/.webhands,
            # which is the per-slot directory that module declares for exactly
            # that, so it is the same write an `anonctl use` shell makes.)
            HOME = "/home/${account}";
            # Everything the server WRITES, away from the home and away from every
            # other instance.
            WHEREVER_STATE_DIR = "/var/lib/wherever-anon/${account}/server";
            WA_STATE_FILE = cfg.statePaths.${account};
            WA_SOCKET_PATH = cfg.socketPaths.${account};
            WA_CONFIG_DIR = "/run/${unitNameFor account}";
          }
          # THE LOGIN PROFILE DOES NOT REACH THIS UNIT, which is the trap. An anon
          # login shell gets both of these from the ~/.bash_profile that
          # modules/anon-home.nix declares, but this unit declares its environment
          # explicitly and reads no profile. Without them a hosted session that can
          # finally START a browser still cannot USE it:
          #   - no WEBHANDS_SOCKET: `webhands serve` listens on loopback TCP, which
          #     anonctl's closure drops for this uid, so serve reports ok and every
          #     verb fails against a healthy server;
          #   - no PLAYWRIGHT_BROWSERS_PATH: the wrapper still finds the bundle, but
          #     a session looking for its browser sees an empty
          #     ~/.cache/ms-playwright and reaches for a 150 MB download over Tor,
          #     which is what the first live session actually did.
          # Both are DERIVED from the anon-home declaration, never spelled, so this
          # unit and the login shell cannot name different sockets or browsers. The
          # socket is this slot's own absolute path (declared, so it carries no
          # observed state): one unit per slot, so no shared file forces the
          # $HOME-relative form the profile uses.
          // lib.optionalAttrs anonHome.browser.enable {
            WEBHANDS_SOCKET = anonHome.browser.socketPaths.${account};
            PLAYWRIGHT_BROWSERS_PATH = "${anonHome.browser.package.browsers}";
          };

        serviceConfig = {
          # THE WHOLE POINT, AND THE ONE LINE THAT MUST NEVER CHANGE. Running as
          # the account's own login uid is what puts this process, AND EVERY
          # AGENT SESSION IT HOSTS IN-PROCESS, inside anonctl's `meta skuid`
          # rules. The jail is the kernel's doing, not this file's.
          #
          # THREE systemd KNOBS WOULD SILENTLY UNFORCE IT, so none appears below
          # and none may be added:
          #   - DynamicUser: allocates a DIFFERENT uid, which anonctl's rules do
          #     not name, so every session would egress UNFORCED, IN THE CLEAR,
          #     while `anonctl verify` still reported 15/15 for the account.
          #   - PrivateUsers: maps uids into a namespace, so what the rules match
          #     on is no longer what the process runs as.
          #   - PrivateNetwork: cuts the instance off from the loopback shim that
          #     IS its route to Tor, so it fails closed permanently.
          User = account;
          Group = account;

          ExecStart = startScript;

          # The generated config, per instance, mode 0700. Removed when the unit
          # stops, which takes the rendered token file with it.
          RuntimeDirectory = unitNameFor account;
          RuntimeDirectoryMode = "0700";

          # NO `Restart`, AND THIS IS MEASURED RATHER THAN STYLISTIC. Socket
          # activation IS the retry mechanism: the next connection starts the
          # service again, so a crashed instance recovers on the next request
          # without any restart policy.
          #
          # `Restart = "on-failure"` with `RestartSec = 2` (which this module
          # carried at first, copied from modules/anon-search.nix) is actively
          # HARMFUL here, because this unit has a DETERMINISTIC startup failure
          # that anon-search does not: it refuses to start when the account has
          # no state or no token, which is the state of EVERY slot until
          # reconcile provisions it.
          #
          # Measured on this box in a `systemd --user` manager, because the
          # obvious reading ("the start limit catches it") is WRONG. Restarting
          # every 2 seconds is EXACTLY the default 5-starts-per-10s limit, so the
          # limit is never exceeded and systemd NEVER GIVES UP: NRestarts reached
          # 15 and was still climbing from a single connection, spawning a
          # process and a log line every two seconds indefinitely.
          #
          # WHAT THIS DOES NOT FIX, stated plainly so nobody re-derives it the
          # hard way. Dropping Restart does NOT keep the socket alive through a
          # startup refusal. A socket-activated service that fails without
          # CONSUMING its pending connection makes systemd re-trigger activation
          # until the start limit, and then the .socket unit fails too. Measured:
          # 5 attempts, then service AND socket both `failed`. Exiting 0 instead
          # of 1 does not help either (same 5 attempts, same dead socket),
          # because the connection is still pending; only actually accepting the
          # connection would avoid it, and that would mean serving while
          # unauthenticated, which is the one thing this unit must never do.
          #
          # So the real choice is between an UNBOUNDED loop and a BOUNDED,
          # visible, repairable failure, and this takes the latter: it fails
          # closed, it shows up in `systemctl --failed`, and it is repaired by
          # exactly `systemctl reset-failed <unit>.socket <unit>.service` then
          # `systemctl start <unit>.socket` (verified: the next connection then
          # serves normally). That repair belongs to reconcile, which is the
          # thing that provisions the state in the first place, and it is
          # recorded in anon-ledger-reconcile-core's state-shape contract.
          #
          # In the normal flow this never fires: the dispatcher only routes to
          # slots reconcile has provisioned, so nothing connects to an
          # unprovisioned one.

          # PRIVATETMP IS PRIVACY, NOT HARDENING, and it is the line here most
          # likely to look droppable. wherever's `resolveDownloadRoots` always
          # adds the resolved upload dir to what `/session/download` will serve,
          # and that dir defaults to `os.tmpdir()`. A shared /tmp therefore makes
          # every readable file under /tmp fetchable by whoever holds this
          # instance's token: other slots' uploads, and whatever the operator
          # left there. A private /tmp makes the upload dir and the download root
          # this instance's own.
          PrivateTmp = true;

          # NO EnvironmentFile ANYWHERE, and that is deliberate rather than
          # incidental. modules/wherever.nix carries the operator's GH_TOKEN
          # through one, and its own option documentation names this exact
          # hazard: a jailed identity holding the operator's token authenticates
          # AS THE OPERATOR, which destroys the point of the account. This unit
          # is a separate unit with an explicit `environment` block, so there is
          # no mechanism by which it could inherit one.

          # THE CREDENTIAL BOUNDARY, made structural rather than documented.
          # `tmpfs` empties /home for this service and BindPaths puts back only
          # this account's own home, so the operator's ~/.ssh, ~/.gitconfig,
          # ~/.config/gh and ~/.pi are not merely unreadable, they do not exist
          # in this unit's view of the filesystem. A permissions mistake on the
          # operator's home therefore cannot become an anon session's credential.
          ProtectHome = "tmpfs";
          BindPaths = ["/home/${account}"];

          # Sandboxing, kept to what CANNOT interfere with the uid identity or
          # the route to the shim (see the three forbidden knobs above).
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          StateDirectory = "wherever-anon/${account}/server";
          StateDirectoryMode = "0700";
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
          # AF_INET/AF_INET6 are REQUIRED: that is the hop to the account's
          # loopback shim, i.e. the route to Tor. AF_UNIX is the inherited
          # listening socket and the model endpoint is reached over AF_INET.
          RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
          SystemCallArchitectures = ["native"];

          # THE SYSCALL POLICY IS MEASURED, NOT GUESSED, and it is the narrowest
          # one that lets this unit host a browser. The allowlist below used to
          # end at "~@resources", and Chromium could not start under it (SIGSYS
          # in the main process, or "GPU process isn't usable" once that was
          # avoided). systemd's SystemCallLog named what it actually calls
          # outside that allowlist, over the whole webhands workload (serve on a
          # socket, goto, eval, snapshot, screenshot, stop), iterated to a fixed
          # point with no audit message suppressed:
          #   pkey_alloc, pkey_mprotect   (outside @system-service)
          #   setpriority, sched_setaffinity   (in @resources)
          #   capset   (in @privileged)
          # Then leave-one-out with SystemCallErrorNumber=EPERM: ONLY capset is
          # REQUIRED (without it the GPU child cannot spawn and Chromium aborts);
          # the other four fail with EPERM and Chromium carries on.
          #
          # So two lines, and each is a decision:
          #   - capset is ADDED BACK. It is inert here: this uid is not root, so
          #     its permitted and inheritable sets are empty, NoNewPrivileges
          #     stops it gaining any, and capset(2) can only set capabilities
          #     within those sets, i.e. it can only drop what it does not have.
          #   - a denied call returns EPERM instead of KILLING the process. This
          #     permits nothing new (the denied set is the same set), it only
          #     makes a denial survivable. The cost, stated: code probing the
          #     filter from inside a session learns a call is blocked instead of
          #     dying, and a session can no longer be killed by a stray `nice`.
          # The rejected alternative, also measured: keep the kill action and
          # allow all five. It works, and it opens four more calls to buy
          # nothing Chromium needs. Unconditional rather than tied to
          # browser.enable, because a session can launch ANY Chromium (a repo's
          # own Playwright) and the measurement applies to it just the same.
          # Evidence: work/notes/findings/chromium-dies-under-a-systemcallfilter-allowlist.md
          SystemCallFilter = ["@system-service" "~@privileged" "~@resources" "capset"];
          SystemCallErrorNumber = "EPERM";
        };
      })
    cfg.accounts);
  };
}
