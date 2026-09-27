# modules/anon-search.nix
#
# A SearXNG per anon account, RUNNING AS THAT ACCOUNT'S OWN LOGIN UID and
# serving HTTP over a unix socket in that account's home. This is ADR-0017
# built. Pairs with modules/anon-home.nix, which delivers the pi-webveil
# extension and writes the `webveil.json` that names these sockets.
#
# WHY AS THE ACCOUNT'S UID, which is the whole design in one sentence. anonctl's
# forcing rules match `meta skuid <uid>`, so a daemon running under the
# account's uid is forced by exactly the same kernel rules as the account's
# interactive shell: its egress goes through the account's shim into Tor, and
# Tor's `<account>@` SOCKS isolation gives it that account's own circuit with
# nothing to configure. Two accounts get two circuits as a CONSEQUENCE of the
# design rather than as a setting someone must remember.
#
# The alternative (a shared SearXNG beside the accounts, reached through a
# loopback exemption, anonymised by its own proxy config) was rejected in
# ADR-0017 because of where the anonymity would then live: if `egressProxies`
# were empty, misspelled or pointed at a dead port, every search would leave via
# the box's real IP WHILE `anonctl verify` CONTINUED TO REPORT 15/15, because
# verify measures the account's own sockets and cannot see a helper service
# making requests on its behalf. Here, even a wholly tampered SearXNG cannot
# deanonymise the account, because its packets are still forced by the kernel.
#
# A UNIX SOCKET IS NOT A STYLE CHOICE. An anon account CANNOT SERVE A LOOPBACK
# TCP PORT AT ALL: anonctl's closure ends in
# `meta skuid <anon> ip daddr 127.0.0.0/8 drop`, and an inbound connection's
# REPLY packets carry the LISTENING socket owner's uid, so the SYN arrives (there
# is no input chain) and the SYN-ACK is dropped. The handshake never completes.
# A loopback exemption does NOT rescue it either: anonctl's exemption clause is a
# single `tcp dport` match and the reply direction's dport is an ephemeral port
# no exemption can name. A unix socket is not IP traffic and traverses no
# nftables chain at all. All measured:
# work/notes/findings/anon-uid-cannot-serve-inbound-tcp-the-reply-is-dropped.md
#
# NOT A uWSGI VASSAL, AND THIS REVERSED AN ADR DECISION. nixpkgs' services.uwsgi
# declares exactly ONE systemd unit (the Emperor) and vassals are its child
# processes, while systemd socket activation hands an fd to a systemd SERVICE
# via LISTEN_FDS. So "an additional vassal" and "socket-activated" are mutually
# exclusive, and these are standalone service+socket units OUTSIDE the Emperor.
# `services.searx` is a singleton and is not touched at all, which makes this
# purely additive: the operator's own instance cannot regress.
#
# `http-socket = fd://3` IS MANDATORY AND NON-OBVIOUS. uWSGI auto-adopts a
# systemd-passed fd as a *uwsgi-protocol* socket, which webveil cannot read; an
# HTTP request against that yields `invalid request block size: ...skip` and an
# empty body. The explicit `fd://3` is what makes the inherited fd speak HTTP.
# Measured, along with the other two socket-activation traps (vacuum is safe;
# chmod-socket/chown-socket are unnecessary because systemd owns the socket):
# work/notes/findings/pi-loads-store-path-extensions-and-uwsgi-socket-activation-needs-fd3.md
#
# ONE INSTANCE PER DECLARED SLOT, DELIBERATELY, and socket activation is what
# makes that free. The instance set does NOT follow which accounts are actually
# forced: that would need an explicit list in the host file (anonctl's ledger is
# imperative state Nix cannot read), and such a list would record WHICH SLOTS
# ARE IN USE AND WHEN EACH BECAME SO, IN GIT HISTORY, which is precisely the
# timing leak modules/anon-accounts.nix declares its whole pool at once to avoid.
# An unused instance costs a socket inode and no Python process (measured), so
# uniform declaration costs nothing.
#
# SEARCH QUALITY IS PER-ACCOUNT AND IT FLICKERS, which is a consequence of the
# circuit isolation above rather than a defect, and is written down here because
# a live session hit it and it looked like a bug. Each account is pinned to its
# OWN Tor exit (that is the point), and engines gate on a per-exit REQUEST
# BUDGET spent largely by strangers sharing that exit, so an engine can refuse
# one request and answer the next. Measured on this box, on one account's own
# exit: duckduckgo returned 403 then 200, while bing returned 200 then failed,
# within minutes. Two consequences are designed for rather than hoped away: the
# engine list is FOUR so that a flicker degrades the result instead of emptying
# it, and the suspension times are minutes rather than upstream's days so that
# one refusal does not remove an engine until tomorrow.
#
# NO KEYED ENGINE, EVER. The operator's instance has a Brave API key; an anon
# instance must not, because an API key is both a credential and an attributable
# ACCOUNT, so it would tie every search to a payment identity and undo the
# entire exercise. That is why this module is short while modules/searxng.nix is
# 756 lines: most of that module is the key machinery (searx-init, the envsubst
# grammar, the substitution guard, the secret-grammar assertions), and none of
# it applies here.
#
# AND NO `outgoing.proxies`, WHICH LOOKS LIKE AN OMISSION AND IS NOT. The
# operator's instance NEEDS egressProxies (its crawl goes out through Mullvad
# because the house IP was flagged). This one must NOT have them: its egress is
# already forced by the kernel, a proxy here would be a second hop the forcing
# redirects anyway, and the account cannot reach any proxy port but its own
# shim's, so it would simply fail closed. Same inversion as the `egress =
# direct` in each account's webveil.json, and the same trap for a later editor.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.anonSearch;
  anonHome = config.nixos-modules.anonHome;

  # uWSGI is derived from the SearXNG package's OWN interpreter, so
  # overriding `package` moves both halves at once. (In the my-boxes fleet this
  # came from a separate recent nixpkgs; here it is whichever pkgs imports us,
  # and a consumer on a stable pin can point `package` at a newer SearXNG.)

  # THE INTERPRETER PIN, and the reason it is written here rather than inherited.
  # A uWSGI built against a DIFFERENT python than the SearXNG package simply
  # cannot import it, and nothing catches that at eval time: the box would just
  # fail to serve. modules/searxng.nix pins `services.uwsgi.package` for the
  # Emperor by the same rule and its comment anticipated exactly this ("if one
  # is ever added it inherits this interpreter"). These units are NOT under the
  # Emperor, so they cannot inherit it and must derive it the same way instead:
  # one derivation's python by construction, not two settings to keep in sync.
  uwsgiPackage = pkgs.uwsgi.override {
    plugins = ["python3"];
    python3 = cfg.package.pythonModule;
  };

  # Exactly what the packaged searx module builds for its vassal, by the same
  # route (uwsgi.nix: `python.withPackages (c.pythonPackages)` then
  # `pyhome = "${pythonEnv}"`), so this instance and the operator's differ in
  # configuration only, never in how the app is assembled.
  pythonEnv = uwsgiPackage.python3.withPackages (_: [cfg.package]);

  yaml = pkgs.formats.yaml {};

  # ONE settings file for every account, not one per slot, because nothing in it
  # is per-account: the socket arrives as fd 3 from systemd, the secret is
  # generated per start, and the state directory is named by the unit. Anything
  # that DID differ per account would be a reason for two slots to behave
  # differently, which modules/anon-home.nix exists to prevent (every slot gets
  # a byte-identical home). Keeping it shared also keeps slot names out of one
  # more store path.
  settingsFile = yaml.generate "anon-searxng-settings.yml" {
    use_default_settings = {
      # The engines NOT listed do not merely sit disabled, they do not exist in
      # the instance. See the `engines` option for what survives Tor.
      engines.keep_only = cfg.engines;
    };

    general = {
      debug = false;
      # Deliberately GENERIC and deliberately not the account name. It renders
      # into the HTML UI, and while a slot name is allowed in the store it has
      # no business in a page that could be screenshotted.
      instance_name = "anon-search";
      # No contact address, no donation link: an anon instance has no operator
      # to name.
      contact_url = false;
    };

    search = {
      # The JSON API webveil talks to. `html` rides along so the instance can be
      # curl'd through the socket while debugging; `json` is the required one.
      formats = ["json" "html"];

      # SHORT SUSPENSIONS, AND THIS IS THE ONE SETTING A TOR INSTANCE CANNOT
      # TAKE FROM UPSTREAM. Upstream benches an engine for a DAY on an access
      # denial or a captcha (86400), an hour on a 429, and FIFTEEN DAYS on a
      # Cloudflare captcha. Those numbers assume the block is a verdict about
      # the instance, which is true for a fixed datacenter IP and false here.
      #
      # On a shared Tor exit a block is a statement about that EXIT'S RECENT
      # TRAFFIC, spent largely by strangers, and it lifts in minutes. Measured
      # on the box: an engine returned 403 on one request and 200 on the same
      # circuit and the same exit a few minutes later, while another engine went
      # the other way in between. Keeping upstream's numbers would turn a
      # transient, shared-exit hiccup into an engine that is GONE FOR A DAY, and
      # with a short engine list that is how a query comes back empty.
      #
      # modules/searxng.nix already makes this argument for the operator's
      # instance and overrides the 429 case; the reasoning applies harder here,
      # so all of the classes are overridden rather than one.
      suspended_times = {
        SearxEngineAccessDenied = cfg.suspendSeconds;
        SearxEngineCaptcha = cfg.suspendSeconds;
        SearxEngineTooManyRequests = cfg.suspendSeconds;
        cf_SearxEngineCaptcha = cfg.suspendSeconds;
        cf_SearxEngineAccessDenied = cfg.suspendSeconds;
        recaptcha_SearxEngineCaptcha = cfg.suspendSeconds;
      };
    };

    server = {
      # The limiter and bot protection are what turn a fresh instance into 429s
      # for a programmatic client. Off is a hard requirement of the webveil
      # backend, and safe: only this account can open the socket.
      limiter = false;
      public_instance = false;
      # Belt and braces. uWSGI binds independently (fd 3 from systemd), so these
      # only matter if the built-in server is ever reached; they exist so no code
      # path here can produce a listener on a port. Note that an anon uid could
      # not SERVE such a port anyway (see the header), so this is a second lock
      # on a door the kernel already welded shut.
      bind_address = "127.0.0.1";
      port = 8888;
      # `secret_key` is deliberately ABSENT here and supplied per start through
      # SEARXNG_SECRET, which searx's settings loader treats as an override
      # ("override existing value with environ", settings_defaults.py). A
      # constant in the store would be world-readable, and persisting one in the
      # account's state would leave a stable per-account value on disk for no
      # benefit: it signs preference cookies for a single-user instance whose
      # only client is its own owner.
    };

    outgoing = {
      # RAISED FROM UPSTREAM'S 3.0s BECAUSE THE EGRESS IS TOR. Measured
      # round-trips from this box through Tor to the two engines that answer:
      # 0.62s to 2.67s, against a 3.0s default that a slow circuit would blow
      # through routinely. Circuit variance is the point: the same query on a
      # different circuit differed by 4x, and one circuit returned 403 outright.
      # SearXNG queries engines in PARALLEL, so this bounds the slowest engine
      # rather than their sum, which is why the headroom is cheap.
      request_timeout = cfg.requestTimeout;
    };

    # Every kept engine explicitly enabled: upstream ships some of them
    # default-off (bing is `disabled: true` in the shipped settings.yml), so the
    # option's value IS the engine set only if each is force-enabled here.
    engines =
      map (name: {
        inherit name;
        disabled = false;
      })
      cfg.engines
      # The browser's recipes, one engine each (see `browser` below). Appended
      # rather than listed in keep_only: SearXNG applies keep_only to its OWN
      # engine list and then appends every user engine it does not know.
;
  };

  # ONE uWSGI config for every account, for the same reason the settings file is
  # shared: the socket is fd 3 and the settings path is common, so nothing in it
  # is per-account.
  uwsgiJson = pkgs.writeText "anon-searxng-uwsgi.json" (builtins.toJSON {
    uwsgi = {
      # Reject an unknown key rather than ignoring it, so a typo here fails the
      # unit instead of silently changing nothing.
      strict = true;
      plugins = ["python3"];
      pyhome = "${pythonEnv}";
      module = "searx.webapp";

      # THE LOAD-BEARING LINE. `http-socket` (not `socket`) because webveil
      # speaks HTTP over the unix socket and cannot read the uwsgi protocol;
      # `fd://3` because systemd already created, bound and chowned the socket
      # and passed it as fd 3. Without the explicit form uWSGI would still adopt
      # the inherited fd, but as a uwsgi-protocol socket, and every search would
      # come back empty with `invalid request block size ...skip` in the log.
      http-socket = "fd://3";

      # Fail LOUDLY if the app cannot be imported, rather than accepting the
      # connection and serving errors. The interpreter pin above is what usually
      # breaks this, and it breaks totally rather than subtly.
      need-app = true;

      lazy-apps = true;
      enable-threads = true;
      buffer-size = 32768;
      master = true;
      processes = 1;
      # SIGTERM means stop, which is what systemd sends. uWSGI's default reads
      # it as "brutal reload".
      die-on-term = true;
      # NO `vacuum`: systemd created the socket and removes it (RemoveOnStop
      # below). uWSGI only vacuums sockets it made itself, so setting it would
      # be harmless but misleading about who owns the file.
      env = [
        "PATH=${pythonEnv}/bin"
        "SEARXNG_SETTINGS_PATH=${settingsFile}"
      ];
    };
  });

  # A FRESH SECRET PER START, never stored. `exec` matters: it preserves both
  # the PID (so systemd's LISTEN_PID still matches) and fd 3 (the socket), which
  # a forked child would not.
  startScript = pkgs.writeShellScript "anon-search-start" ''
    set -euo pipefail
    SEARXNG_SECRET="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0)"
    export SEARXNG_SECRET
    exec ${uwsgiPackage}/bin/uwsgi --json ${uwsgiJson}
  '';

  unitNameFor = account: "anon-search-${account}";

in {
  options.nixos-modules.anonSearch = {
    enable = lib.mkEnableOption ''
      a SearXNG per anon account, each running as that account's own uid and
      serving over a unix socket in its home (ADR-0017).

      Needs nixos-modules.anonHome.webTools.enable on the same host: that is what delivers
      the pi-webveil extension and writes the webveil.json naming these sockets.
      Enabling this alone would serve sockets nothing reads; enabling that alone
      gives a working web_fetch and a web_search with no backend
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.searxng;
      defaultText = lib.literalExpression "pkgs.searxng";
      description = ''
        The SearXNG build to run, defaulting to the `nixpkgs-recent` one for the
        same reason modules/searxng.nix does: SearXNG is a pile of engine
        scrapers and an old snapshot silently returns nothing at all.

        The uWSGI these units run is derived FROM this package's own interpreter
        (`pythonModule`), so overriding this moves both halves at once and they
        cannot drift into a build that cannot import its own app.
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

        That is deliberate and is a privacy property rather than a convenience:
        a list of active accounts would have to live in the host file, and it
        would record which slots are in use and when each became so, in git
        history. Socket activation is what makes declaring all of them free.
      '';
    };

    engines = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["duckduckgo" "bing" "mwmbl" "wiby"];
      description = ''
        The keyless engines this instance keeps. NOT the operator instance's
        list, because the egress is Tor.

        MEASURED 2026-09-22/23 from inside a forced account's own circuit, with
        a browser User-Agent (SearXNG sends one; a bare curl probe is
        meaningless and misreports in BOTH directions):

          duckduckgo  answers, full result pages. Also the engine most likely to
                      return a TRANSIENT 403 on a busy exit.
          bing        answers, full result pages, but shallow on technical
                      queries: it returned project landing pages where mwmbl
                      returned the actual topic.
          mwmbl       answers, and kept answering on an exit where duckduckgo
                      was 403 and bing was failing.
          wiby        answers, small hand-curated index, same story.
          brave       429 with captcha markers on every circuit tried.
          mojeek      TCP connection never completes over Tor, AND serves a
                      captcha even on a DIRECT request from the house, so it is
                      dead on every egress class rather than a Tor casualty.
          startpage   not an engine at all: `inactive: true` upstream in this
                      package vintage, a proof-of-work captcha.
          marginalia  likewise `inactive: true` upstream, so unavailable.

        WHY FOUR AND NOT THE TWO BIG ONES. mwmbl and wiby are small indexes that
        will not carry a general query alone, and they are here for REDUNDANCY
        rather than reach. Engine availability on Tor flickers minute to minute
        because the gate is a per-exit REQUEST BUDGET spent largely by strangers
        (work/notes/findings/search-engine-gatekeeping-by-egress-class.md), and
        a Tor exit is the worst case for that model. Measured on this box: on
        one account's own exit, duckduckgo went 403 then 200, and bing went 200
        then failed, within minutes of each other. With two engines such a
        flicker returns an EMPTY result set, which is what a live session hit;
        with four it degrades instead. They cost nothing when they fail.

        A KEYED ENGINE MUST NEVER APPEAR HERE. An API key is a credential and an
        attributable account; adding one would tie every search to a payment
        identity. An assertion below refuses the ones this fleet has a key for.
      '';
    };

    suspendSeconds = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 300;
      description = ''
        How long an engine is benched after it refuses a request, for EVERY
        refusal class (access denied, captcha, 429, and the Cloudflare and
        reCAPTCHA variants). Upstream's values are 3600 for a 429, 86400 for an
        access denial or captcha, and 1296000 for a Cloudflare captcha.

        Those assume a block is a verdict about this instance, which holds for a
        fixed datacenter IP and does not hold here: on a shared Tor exit a block
        is about that exit's recent traffic and lifts in minutes. Upstream's
        numbers would turn a transient hiccup into an engine that is gone for a
        day, which with a short engine list is how a query returns nothing.

        Not shorter than this without thought: retrying a genuinely blocked
        engine spends the exit's budget and makes the problem worse for everyone
        sharing it, including this account's next query.
      '';
    };

    requestTimeout = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 10.0;
      description = ''
        Per-engine request timeout in seconds, raised from upstream's 3.0
        because every request crosses Tor.

        Measured round-trips from this box through Tor to the engines that
        answer were 0.62s to 2.67s, so 3.0 leaves almost no headroom and a slow
        circuit would time out a query that was about to succeed. SearXNG
        queries engines in PARALLEL, so this bounds the SLOWEST engine and not
        the sum of them, which is why the headroom costs so little.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = anonHome.enable;
        message = ''
          nixos-modules.anonSearch.enable is on but nixos-modules.anonHome.enable is off, so
          there are no declared anon accounts to serve and `accounts` would be
          empty. Enable nixos-modules.anonHome (which declares the home content these
          instances back) or turn this off.
        '';
      }
      {
        assertion = anonHome.webTools.enable;
        message = ''
          nixos-modules.anonSearch.enable is on but nixos-modules.anonHome.webTools.enable is
          off, so these instances would serve sockets that nothing reads: the
          accounts have no pi-webveil extension and no webveil.json naming the
          socket. The two options are halves of one feature (ADR-0017); enable
          webTools as well, or turn this off.
        '';
      }
      {
        # The socket path is the CONTRACT between this module and anon-home: one
        # side serves it, the other names it in webveil.json. They read it from
        # the same read-only attrset, so this can only fire if someone adds an
        # account to one list and not the other.
        assertion = lib.all (a: anonHome.webTools.searchSocketPaths ? ${a}) cfg.accounts;
        message = ''
          nixos-modules.anonSearch.accounts names an account with no socket path in
          nixos-modules.anonHome.webTools.searchSocketPaths
          (${lib.concatStringsSep ", " (lib.subtractLists (lib.attrNames anonHome.webTools.searchSocketPaths) cfg.accounts)}).

          That path is the contract between this module and modules/anon-home.nix:
          this module serves the socket and that module writes the webveil.json
          naming it. An account in one list and not the other gets a backend
          nothing points at, or a config pointing at a socket nothing serves.
        '';
      }
      {
        # Belt and braces against the one content mistake that would undo the
        # whole design. `braveapi` is the keyed engine this fleet actually has a
        # key for, so it is the realistic way this happens: someone copies the
        # operator's engine list across.
        assertion = !(lib.any (e: lib.hasSuffix "api" e || e == "brave_api") cfg.engines);
        message = ''
          nixos-modules.anonSearch.engines names what looks like a KEYED engine
          (${lib.concatStringsSep ", " (lib.filter (e: lib.hasSuffix "api" e || e == "brave_api") cfg.engines)}).

          An anon instance must carry no keyed engine at all: an API key is both
          a credential and an attributable ACCOUNT, so it would tie every search
          this jailed identity makes to a payment identity and undo the point of
          the account. The operator's instance is where a keyed engine belongs
          (modules/searxng.nix), not this one.
        '';
      }
    ];

    # The per-account socket DIRECTORY, 0700 and account-owned. In /run rather
    # than the home (see nixos-modules.anonHome.webTools.searchSocketPaths for why), which
    # means it is a tmpfs and is rebuilt from these rules on every boot, so a
    # stale socket cannot survive a crash or a power cut. The 0700 mode carries
    # the defence-in-depth the 0700 home used to: the socket's own 0600 mode and
    # ownership are the actual gate, this is the second lock.
    #
    # Ordering is safe without stating it: systemd-tmpfiles-setup runs in
    # sysinit.target, which precedes basic.target and therefore sockets.target,
    # so the directory exists before any of these sockets binds.
    systemd.tmpfiles.rules =
      ["d /run/anon-search 0755 root root -"]
      ++ map (account: "d /run/anon-search/${account} 0700 ${account} ${account} -") cfg.accounts;

    # THE SOCKET. systemd creates, binds, chowns and chmods it as root BEFORE
    # the service runs, which is what lets a socket owned by the account exist
    # inside a 0700 directory it could not itself have created there. This is
    # why no `chmod-socket` / `chown-socket` / setgid parent directory appears
    # anywhere in this module, unlike the operator's instance.
    systemd.sockets =
      lib.listToAttrs (map (account:
        lib.nameValuePair (unitNameFor account) {
          description = "Search backend socket for anon account ${account}";
          wantedBy = ["sockets.target"];
          socketConfig = {
            ListenStream = anonHome.webTools.searchSocketPaths.${account};
            SocketUser = account;
            SocketGroup = account;
            # 0600: only the owning account can connect. `connect()` needs write
            # permission on the socket file, so ownership IS the access control
            # and nothing else is needed. The 0700 home is a second lock.
            SocketMode = "0600";
            # Never leave a stale socket file behind in an account's home.
            RemoveOnStop = true;
          };
        })
      cfg.accounts);

    systemd.services =
      lib.listToAttrs (map (account:
        lib.nameValuePair (unitNameFor account) {
          description = "SearXNG for anon account ${account} (runs as that account, forced through its own Tor circuit)";

          # NO `wantedBy`. This is socket-activated: the unit must start on the
          # first connection and not at boot, which is what makes one instance per
          # declared slot cost a socket inode instead of a Python process.
          requires = ["${unitNameFor account}.socket"];
          after = ["${unitNameFor account}.socket" "network.target"];

          serviceConfig = {
            # THE WHOLE POINT, AND THE ONE LINE THAT MUST NEVER CHANGE. Running as
            # the account's own login uid is what puts this process inside
            # anonctl's `meta skuid` rules, so its egress is forced through the
            # account's shim into Tor by the kernel rather than by anything in
            # this file.
            #
            # THREE systemd KNOBS WOULD SILENTLY BREAK THAT, so none of them
            # appears below and none may be added:
            #   - DynamicUser: allocates a DIFFERENT uid, which anonctl's rules do
            #     not name, so the instance would egress UNFORCED, in the clear,
            #     while `anonctl verify` still reported 15/15 for the account.
            #     This is the exact failure ADR-0017 rejected the alternative
            #     design over, and DynamicUser would reintroduce it by accident.
            #   - PrivateUsers: maps uids into a namespace, so what the rules match
            #     on is no longer what the process runs as.
            #   - PrivateNetwork: cuts the instance off from the loopback shim that
            #     IS its route to Tor, so it would fail closed rather than leak,
            #     but it would fail closed permanently.
            User = account;
            Group = account;

            ExecStart = startScript;

            # Volatile state only, never the account's home. Note this protects
            # nothing FROM the account (same uid, so anything the service can
            # write the account can write); what protects the design is that the
            # CONFIGURATION is read-only in the store and that egress is not
            # configurable by anybody, being enforced by kernel rules on the uid.
            StateDirectory = unitNameFor account;
            StateDirectoryMode = "0700";
            # Keep anything that consults HOME out of the real home.
            Environment =
              ["HOME=%S/${unitNameFor account}"];

            Restart = "on-failure";
            RestartSec = 2;

            # PRIVATETMP IS LOAD-BEARING FOR PRIVACY, NOT HARDENING, and this is
            # the one line here that would look droppable and is not. SearXNG's
            # cache is a SQLite file whose path defaults to
            # `tempfile.gettempdir() + "/sxng_cache_<name>.db"` (searx/cache.py),
            # i.e. a FIXED name in a SHARED /tmp. Without a private /tmp every
            # instance on the box collides on one file: the operator's own
            # SearXNG already owns /tmp/sxng_cache_DATA_CACHE.db as the `searx`
            # user, so an anon instance either fails to start (measured:
            # `sqlite3.OperationalError: attempt to write a readonly database`,
            # then `need-app requested, destroying the instance`) or, if the modes
            # ever lined up, would SHARE A SEARCH CACHE WITH THE OPERATOR AND WITH
            # EVERY OTHER SLOT. That is a correlation channel between identities
            # that are supposed to be unrelated, which is the whole thing this
            # module exists to prevent.
            #
            # With it, each service gets its own tmpfs, so every slot's cache is
            # private AND ephemeral, which is the right lifetime for an anon
            # account's search history anyway: nothing survives a restart.
            #
            # Measured 2026-09-22 by running this module's own generated config
            # under socket activation: it FAILED without this line and returned
            # ten results over the socket with it.
            PrivateTmp = true;

            # Sandboxing, kept to what CANNOT interfere with the uid identity or
            # the route to the shim (see the three forbidden knobs above).
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
            # AF_INET/AF_INET6 are REQUIRED: this is the hop to the shim, i.e. the
            # route to Tor. AF_UNIX is the inherited listening socket.
            RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
            SystemCallArchitectures = ["native"];
            SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
          };
        })
      cfg.accounts);
  };
}
