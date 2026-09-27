# modules/anon-home.nix
#
# THE CONTENT of anonctl's anon account homes, so a slot is a working,
# CREDENTIAL-FREE agent the moment it is entered. Third sibling to
# modules/anon-accounts.nix (the passwd slots) and modules/anon-dns.nix (name
# resolution); this one owns what is INSIDE the home and nothing else. It
# declares no nftables rule, no unit and no anonctl invocation, and it must
# never run anonctl at activation: the forcing, the ledger and the exemptions
# stay anonctl's own imperative state.
#
# WHY THE HOST OWNS THIS AT ALL, which is a deliberate split rather than a gap
# anonctl forgot. anonctl 0.6.1 CAN seed a home, from the directory-exists
# convention `/etc/anonctl/default-home/`, and it refuses to use it here:
#
#     // On FRESH creation only ... An ADOPTED account (Created=false) is never
#     // seeded, mirroring the login-env write: its home is whoever declared
#     // it's, and anonctl is not entitled to drop files into it.
#                                                   (anonctl main.go, `add`)
#
# On this box EVERY anon account is adopted, by construction and permanently:
# modules/anon-accounts.nix declares the slots because `users.mutableUsers =
# false` would otherwise delete them at each activation, so they always exist
# before `anonctl add` runs and `res.Created` is always false. So
# `/etc/anonctl/default-home/` would never fire for a single account on this
# host, and the module that declared the accounts is exactly the "whoever
# declared it" anonctl is deferring to. Hence: here.
#
# WHAT THE SYMPTOM WAS. `sudo anonctl use anon-01`, then `pi`, warned "No
# models available". Not a broken jail and not a broken model server: the
# account simply had no provider configuration at all, because
# nixos-modules.piUser is scoped to `user = "wighawag"` and nothing had ever
# written into an anon home.
#
# ── THE ALLOWLIST IS THE SECURITY BOUNDARY ──────────────────────────────────
#
# An anon account exists to be UNATTRIBUTABLE, so the question for every file
# is not "is it useful" but "does it carry identity". Nothing identity-bearing
# may land here: no sops secret, no API key, no auth.json, no GitHub token, no
# git user.name/email, no ssh key, no path naming the operator.
#
# That rule is enforced by CONSTRUCTION rather than by this comment, in three
# ways, because a documented rule is one careless option away from a leak.
# THEY ARE DIFFERENT KINDS OF GUARD and the difference matters:
#
#   1. PROVENANCE. Every file source must be a STORE PATH (`isStorePath`). A
#      repo-relative path literal interpolates to /nix/store/...; a sops secret
#      is `config.sops.secrets.<x>.path`, i.e. the STRING "/run/secrets/<x>",
#      which interpolates to itself and is refused at evaluation. sops-nix
#      decrypts at ACTIVATION and never renders into the store, so for SOPS
#      specifically, "is a store path" and "is not a secret" are the same test.
#
#      THIS PROVES NOTHING ABOUT CONTENT, and saying otherwise was this
#      module's first bug. `agentsFile = ../../hosts/telemaque/home/.pi/agent/AGENTS.md`
#      is a store path and passes, and it is the operator's portrait: exactly
#      the failure the agentsFile option calls the most direct way this module
#      could fail. So provenance is necessary and nowhere near sufficient.
#
#   2. CONTENT. Everything this module renders into an anon home is SCANNED at
#      evaluation (`contentOffenders`) and the build fails if it carries a
#      credential-shaped literal (/run/secrets, ghp_/gho_/github_pat_, sk-, a
#      PRIVATE KEY block, an apiKey that is not "none") or the NAME OF ANY
#      OTHER ACCOUNT ON THIS BOX. That last one is derived from
#      `users.users` rather than hardcoded, so it needs no maintenance and
#      catches the operator's home path, their username in a prose file, and
#      any future human account, without this module being told who they are.
#      ADR-0013 asks for exactly this check, in these words: "the declared seed
#      must contain no credential-shaped literal", converting a runtime refusal
#      into a build-time impossibility.
#
#      PLUS ONE EXACT-MATCH CHECK for the named worst case: an agentsFile whose
#      content equals the OPERATOR's declared policy file is refused outright.
#      That check is not redundant, it is load-bearing, and the measurement says
#      why: the operator's AGENTS.md on this box contains ZERO occurrences of
#      their username. It is a portrait drawn in conventions rather than names,
#      so the substring scan above does not see it at all.
#
#      ITS LIMITS, STATED, because a guard trusted past its range is worse than
#      no guard. It scans FILES this module renders or reads (models.json,
#      settings.json, AGENTS.md, the login profile). It does NOT recurse into a
#      `skills` directory: that is a store tree of unbounded size and eval-time
#      recursion over it is not worth the build cost, so a skill is covered by
#      provenance only, which is one more reason the default skill set is empty.
#      And it cannot catch a file that is identity-bearing WITHOUT containing a
#      username or a credential shape, which, per the measurement above, is a
#      real category and not a theoretical one. For that, the defences are the
#      default (a purpose-written anon file) and review of the diff. The checks
#      raise the floor; they are not a substitute for reading what you declare.
#
#   3. SCHEMA. The provider record has NO credential field. models.json is
#      BUILT here from `endpoint` + `models`, and `apiKey` is the literal
#      "none", written by this module. There is no option through which a key
#      could be passed, so the rendered file cannot carry one even by mistake.
#      Contrast the operator's models.json, which modules/pi-user.nix correctly
#      calls "~90% CREDENTIALS" and keeps wholly in sops.
#
# ── DECLARED vs SEEDED, the trap modules/pi-user.nix already hit ────────────
#
# A store symlink is READ-ONLY. Anything the application legitimately writes
# to therefore cannot be one (pi-user.nix learned this on auth.json, which pi
# rewrites at every token refresh, and which is consequently seeded rather than
# declared). Sorted for this module:
#
#   models.json    DECLARED (L+). pi never writes it; the operator's own copy
#                  is a 0400 sops file and has worked that way since it landed.
#   settings.json  DECLARED (L+), with eyes open. pi would like to write
#                  `lastChangelogVersion` here and cannot. That is the exact
#                  trade the operator's box already makes and accepts, and it
#                  matters more here: `enabledModels` IS pi's model picker, so
#                  an anon session that could edit it could also point itself
#                  at a provider this module deliberately did not give it.
#   AGENTS.md      DECLARED (L+). It is policy; policy that drifts per account
#                  with no diff and no review is worse than no policy.
#   .bash_profile  DECLARED (L+). Login environment, never written by a tool.
#   .pi/agent/     A REAL DIRECTORY, 0700, owned by the account. pi writes its
#                  session store and any npm extension tree underneath, so the
#                  DIRECTORY must be writable even though the files named above
#                  inside it are not.
#   auth.json      ABSENT, and the one file this module will never declare in
#                  any form. It is where a credential would live.
#
# ── OWNERSHIP: `d` DOES NOT CHOWN AN EXISTING DIRECTORY, `Z` DOES ───────────
#
# hosts/telemaque/default.nix carries the scar: the operator's `.agents` tree
# came out root-owned because only the leaf was declared, and `ln` in their own
# skills directory failed with "Permission denied". Every tree here is
# therefore `d` (create with the right mode) PLUS `Z` (recursively correct the
# ownership of whatever is already there). The group is the ACCOUNT'S OWN
# GROUP, never `users`: modules/anon-accounts.nix gives each slot a dedicated
# group precisely so that group-readable files are not mutually visible between
# the operator and an account whose whole purpose is to be unlinkable to them.
#
# ── ONE ANONYMITY NIT, STATED RATHER THAN DISCOVERED ────────────────────────
#
# Every slot gets a BYTE-IDENTICAL home. If the slots are meant to be DISTINCT
# identities, that identical setup is a shared behavioural fingerprint: same
# standing instructions, same model, same tool surface, so two slots produce
# recognisably the same agent, and anything that correlates their output
# correlates the identities. Against the LAN model this home points at, that is
# minor (the observer is a box on the operator's own shelf). It stops being
# minor if a slot is ever pointed at a REMOTE provider, which is a second
# reason this module only knows how to name a LAN endpoint. Per-slot variation
# is deliberately not offered here: it would have to be real variation in
# instructions and model choice to be worth anything, and a knob that produces
# cosmetic differences would only make the fingerprint look addressed.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.anonHome;

  # The provider id, hardcoded rather than offered as an option. It names the
  # software serving the endpoint (llama.cpp's router) and has to agree with the
  # `<provider>/<model>` strings in enabledModels below; two options that must
  # match each other are a drift source, and nothing about an anon home wants a
  # second provider. It matches the operator's id, which is what makes a model
  # name mean the same thing in both places.
  #
  # WASISABI: with NO `endpoint` (the default here) there is no LAN server to
  # name, and the provider comes from an EXTENSION instead: pi-wasisabi-local
  # registers the machine's own model under `provider`, reaching it over the
  # unix socket (no jail exemption needed). models.json then carries no
  # provider at all, and `provider` is what enabledModels is written against.
  providerId =
    if cfg.endpoint == null
    then cfg.provider
    else "llamacpp-router";

  # A file source is acceptable ONLY if it interpolates to a store path. See
  # guard 1 in the header: this refuses a sops secret, and it is a PROVENANCE
  # test that says nothing about what the file contains. Guard 2 below is the
  # one that reads it.
  isStorePath = p: lib.hasPrefix builtins.storeDir "${p}";

  # Guard 2: the content scan.
  #
  # WHOSE NAMES ARE FORBIDDEN, derived rather than hardcoded. Every normal
  # account on this box that is not itself an anon slot is an identity an anon
  # home must not name: the operator today, whoever else is declared tomorrow.
  # Deriving it from users.users means this cannot rot, and means the module
  # never has to carry the operator's name in its own source.
  foreignNames =
    lib.filter (n: !(lib.elem n cfg.accounts))
    (lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser or false) config.users.users));

  # Credential SHAPES, deliberately narrow. These are value patterns, not
  # vocabulary: an AGENTS.md is allowed to say the word "credential" (this
  # module's own anon policy file does, repeatedly) and must only be refused
  # for carrying one. `"apiKey"` is checked separately below for the same
  # reason: the key name is fine, a value other than "none" is not.
  credentialShapes = [
    "/run/secrets"
    "ghp_"
    "gho_"
    "github_pat_"
    "sk-"
    "PRIVATE KEY"
    "BEGIN OPENSSH"
  ];

  hitsIn = text: lib.filter (needle: lib.hasInfix needle text) (credentialShapes ++ foreignNames);

  # Every rendered or read artifact, by the label a failure should name.
  #
  # THE LABELS ARE PLAIN STRINGS WITH NO STORE-PATH CONTEXT, which is not a
  # style choice: they become ATTRIBUTE NAMES, and Nix refuses a string carrying
  # store-path context in that position ("is not allowed to refer to a store
  # path"). Interpolating cfg.agentsFile into the label made this whole check
  # throw that error INSTEAD of the assertion below, and only on the failing
  # path, so the guard looked like it was passing on a clean config while being
  # incapable of reporting a real hit. Name the OPTION here; the operator can
  # resolve it to a path.
  scanned =
    {
      "models.json" = builtins.toJSON modelsJson;
      "settings.json" = builtins.toJSON settingsJson;
      "the file named by nixos-modules.anonHome.agentsFile" = builtins.readFile cfg.agentsFile;
    }
    // lib.optionalAttrs cfg.loginEnv {
      ".bash_profile" = bashProfile;
    };

  contentOffenders = lib.filterAttrs (_: hits: hits != []) (lib.mapAttrs (_: hitsIn) scanned);

  # Guard 2b: the NAMED worst case, checked by identity rather than by pattern.
  #
  # MEASURED, and it is why this exists: the operator's own AGENTS.md on this
  # box contains ZERO occurrences of their username. It is a portrait drawn in
  # conventions (worktree layout, repo habits, a printer, a systemd unit), not
  # in names, so the substring scan above sails straight past it. Linking it
  # into an anon home is the failure the agentsFile option calls the most direct
  # way this module could fail, and the generic guard cannot see it. So compare
  # the CONTENT against the operator's declared policy file and refuse an exact
  # match.
  operatorAgentsFile = cfg.operatorAgentsFile;
  agentsFileIsOperators =
    operatorAgentsFile != null
    && builtins.readFile cfg.agentsFile == builtins.readFile operatorAgentsFile;

  # models.json, BUILT here. The provider record carries baseUrl, api, apiKey
  # and models, and only `apiKey` is not derived from an option, because it is
  # the literal "none": this endpoint authenticates nobody, which is precisely
  # why an anon account may talk to it.
  # MODELS, WITH THE DECLARED DEFAULT FIRST. This ordering is not cosmetic, it
  # is what makes `defaultModel` actually decide anything.
  #
  # pi 0.80.6's `findInitialModel` (dist/core/model-resolver.js) resolves the
  # startup model in this order:
  #
  #   1. --provider/--model on the command line
  #   2. scopedModels[0]                  <- the FIRST entry of enabledModels
  #   3. defaultProvider + defaultModelId <- what settings.json declares
  #   4. the first model with configured auth
  #
  # `modelPatterns = parsed.models ?? settingsManager.getEnabledModels()`, and
  # `resolveModelScopeWithDiagnostics` pushes matches in PATTERN order, so step
  # 2 is simply "whatever the host happened to list first" and it SHADOWS step
  # 3 whenever enabledModels is non-empty. Declaring `defaultModel` and letting
  # the list order disagree with it would therefore be a setting that silently
  # does nothing, with the real choice made by an accident of formatting.
  #
  # So the module sorts rather than trusting the host to: the declared default
  # is emitted first in BOTH files, which makes steps 2 and 3 agree and makes
  # `defaultModel` authoritative however the host chose to order `models`.
  orderedModels =
    lib.filter (m: m.id == cfg.defaultModel) cfg.models
    ++ lib.filter (m: m.id != cfg.defaultModel) cfg.models;

  modelsJson = {
    providers = lib.optionalAttrs (cfg.endpoint != null) {
    ${providerId} = {
      baseUrl = "http://${cfg.endpoint}/v1";
      api = "openai-completions";
      apiKey = "none";
      models =
        map (m: {
          inherit (m) id name contextWindow maxTokens reasoning;
          input = ["text"] ++ lib.optional m.vision "image";
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        })
        orderedModels;
    };
    };
  };

  settingsJson = {
    defaultProvider = providerId;
    defaultModel = cfg.defaultModel;
    theme = "dark";

    # EXTENSIONS COME FROM THE STORE OR NOT AT ALL, and the empty default is
    # still the right default. pi installs the entries of `packages` FROM npm at
    # session start, and for an anon account every such fetch would cross the
    # jail (npm over Tor), turning session start into a slow network operation
    # that can fail closed. The operator's pinned set is also operator tooling
    # (a remote-control bridge, a transcript searcher over the operator's own
    # history, a subagent runner) and belongs nowhere near here.
    #
    # ADR-0017 reverses this for ONE entry, on the ground that the objection was
    # always the npm FETCH and never the extension: pi-webveil is neither
    # credentialed nor operator-specific, so delivering it as an absolute STORE
    # path passes the allowlist on content and removes the fetch entirely. The
    # path is the package's own `extensionSubdir`, never spelled here, because a
    # wrong subpath fails SILENTLY (pi's local resolution is a bare
    # `if (!existsSync(resolved)) return;`): no warning, no error, exit 0, and
    # an account with no web tools that looks exactly like one that has them.
    #
    # `extensions` below is the same delivery for anything else the host names,
    # in attribute-name order so the rendered list is a function of the set and
    # not of the order someone typed it in. webTools stays first and stays its
    # own option because it also renders a per-account webveil.json; the rest
    # are a list.
    packages =
      lib.optional cfg.webTools.enable
      "${cfg.webTools.package}/${cfg.webTools.package.extensionSubdir}"
      ++ lib.mapAttrsToList (_: p: "${p}/${p.extensionSubdir}") cfg.extensions;

    # This list IS the model picker: pi reads enabledModels when `--models` is
    # absent, so an empty list is the "No models available" warning that
    # started this work. Every entry is a model on the LAN endpoint, and there
    # is deliberately no credentialed provider to name.
    enabledModels = map (m: "${providerId}/${m.id}") orderedModels;
  };

  # webveil's own config, per account because the backend socket is per account.
  # Read identically by the pi-webveil extension and the webveil CLI (webveil
  # resolves env > nearest webveil.json walking up from cwd > the XDG global).
  #
  # `egress = direct` IS THE ANONYMISED SETTING HERE, which reads backwards and
  # is the likeliest thing for a later editor to "fix". It does NOT mean "go out
  # on the real IP". For an anon account the anonymity is ENFORCED BY THE KERNEL
  # on this uid, so every packet webveil sends is already forced through the
  # account's shim into Tor whatever webveil believes. Setting a socks5 egress
  # here would add a SECOND hop the forcing would then redirect anyway, and it
  # would be actively worse in two ways: webveil REFUSES a non-direct egress
  # with a local `baseUrl` (its fail-loud guard against proxying a loopback
  # call, which would be fake anonymity), so search would break outright; and
  # the account cannot reach any proxy port but its own shim's, so it would fail
  # closed regardless. `direct` here means "add no proxy of your own", and the
  # jail supplies the rest. This is the inverse of the operator's instance,
  # where egress is where anonymity lives because nothing else provides it.
  #
  # `fetchEgress` is deliberately UNSET so it inherits `egress`: the `web_fetch`
  # hop is forced by the same kernel rules as every other packet this uid sends.
  webveilJsonFor = account: {
    backend = "searxng";
    baseUrl = "unix:${cfg.webTools.searchSocketPaths.${account}}";
    egress = {mode = "direct";};
    fetchSize = "m";
  };

  # PRIVATE-RANGE IP:port only. See the `endpoint` option and the assertion for
  # why the grammar check is not merely "looks like an address".
  endpointParts =
    builtins.match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3}):([0-9]{1,5})" (toString cfg.endpoint);
  endpointNums =
    if endpointParts == null
    then null
    else map lib.toInt endpointParts;
  endpointOk =
    endpointNums
    != null
    && lib.all (n: n <= 255) (lib.sublist 0 4 endpointNums)
    && (let p = lib.elemAt endpointNums 4; in p >= 1 && p <= 65535)
    && (
      let
        a = lib.elemAt endpointNums 0;
        b = lib.elemAt endpointNums 1;
      in
        a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)
        # WASISABI: loopback too. A model on the SAME machine reached by a
        # loopback exemption (`anonctl --allow 127.0.0.1:<port>`, which anonctl
        # accepts under its stricter loopback guardrail, its ADR-0008) is the
        # fallback when the socket route is not used.
        || a == 127
    );

  # The login environment. See the `loginEnv` option for the measurement this
  # exists to correct.
  bashProfile =
    ''
      # DECLARED by modules/anon-home.nix. This is a read-only symlink into the
      # Nix store: editing it is a repo change plus a converge, not a text editor.
      #
      # WHY THIS FILE EXISTS, AND WHY IT IS READ AT ALL. Three steps, in this
      # order, which is the bit worth getting right because two of them look
      # contradictory out of sequence:
      #
      #   1. `anonctl use` execs `setpriv ... <shell> -l` with argv0 prefixed by
      #      `-`, handing it a deliberately spartan environment whose PATH is
      #      /usr/local/bin:/usr/bin:/bin. On NixOS those three hold nothing but
      #      /usr/bin/env and /bin/sh. anonctl expects the account's own profile
      #      drop-in to refine it, and writes that drop-in only for accounts it
      #      CREATED, so an adopted account (i.e. every account here) has none.
      #   2. Because `-l` makes it a LOGIN shell, bash reads /etc/profile, which
      #      sources set-environment, which OVERWRITES PATH with an absolute list
      #      including /run/current-system/sw/bin. So the spartan PATH from step 1
      #      never survives to be observed: `pi` and `anonctl` resolve fine.
      #   3. Then, still because it is a login shell, bash reads THIS file, which
      #      is therefore the correct and only hook for adjusting what step 2 set.
      #
      # The functional answer is thus "PATH is already sane, the host need not
      # declare a login env to make the account WORK". This file is not here for
      # that.
      #
      # WHAT IS NOT SANE is what that fleet-wide PATH NAMES. modules/dev-toolchain.nix
      # appends the operator's own toolchain prefixes box-wide, so every account on
      # this machine, including this one, gets an environment reading
      # /home/<operator>/.npm-global/bin:/home/<operator>/.cargo/bin:/home/<operator>/go/bin.
      # Those directories are unreachable from here (the operator's home is 0700),
      # so this is not an escape and not a code-execution path: they are dead
      # entries. They are still the operator's NAME, three times, in the
      # environment of a session whose entire purpose is to not be attributable to
      # them, one `echo $PATH` or one env-dumping tool away from an agent's
      # context window.
      #
      # PATH IS ONLY ONE OF TEN. Measured on this box rather than assumed: the
      # generated set-environment names that home in PATH, GTK_PATH, INFOPATH,
      # LIBEXEC_PATH, QTWEBKIT_PLUGIN_PATH, TERMINFO_DIRS, XCURSOR_PATH,
      # XDG_CONFIG_DIRS, XDG_DATA_DIRS and NIX_PROFILES, plus NPM_CONFIG_PREFIX
      # which is a bare value rather than a list. An earlier version of this file
      # filtered PATH alone while its comment claimed to have addressed "the
      # operator's name in the environment", which was nine tenths wrong.
      #
      # THIS IS A MITIGATION, NOT THE ROOT FIX, and the distinction is worth
      # keeping honest. The root fix is that operator-specific prefixes should not
      # be declared box-wide at all (environment.profiles + environment.variables
      # in dev-toolchain.nix and the host). That change alters the OPERATOR's own
      # shell and wherever's unit environment, so it is deliberately not made from
      # here. Until it is, this list is maintained by hand, and an eleventh
      # variable would pass unnoticed: re-check with `sudo -iu <account> env`
      # after any change to the box-wide environment.
      _anon_filter_path_list() {
        # $1 = variable name, $2 = separator. Keeps entries under this account's
        # own HOME, drops entries under any OTHER /home, leaves the rest alone.
        local name=$1 sep=$2 value out= entry oifs
        eval "value=\''${$name-}"
        [ -n "$value" ] || return 0
        oifs=$IFS
        IFS=$sep
        # Pathname expansion off: entries are data, not globs. Without this a
        # literal `*` or `[` in an entry would be expanded against the cwd.
        set -f
        for entry in $value; do
          [ -n "$entry" ] || continue
          case $entry in
            "$HOME" | "$HOME"/*) ;;
            /home/*) continue ;;
          esac
          if [ -z "$out" ]; then out=$entry; else out=$out$sep$entry; fi
        done
        set +f
        IFS=$oifs
        # Never hand back an EMPTY list: if this filter ever matched everything,
        # keep what the system gave us. A stripped identity is worth having; a
        # login with no working binary is not.
        if [ -n "$out" ]; then
          eval "$name=\$out"
          export "$name"
        fi
      }

      for _anon_var in PATH GTK_PATH INFOPATH LIBEXEC_PATH QTWEBKIT_PLUGIN_PATH \
                       TERMINFO_DIRS XCURSOR_PATH XDG_CONFIG_DIRS XDG_DATA_DIRS; do
        _anon_filter_path_list "$_anon_var" :
      done
      # NIX_PROFILES is SPACE-separated, not colon-separated.
      _anon_filter_path_list NIX_PROFILES " "

      # A bare value rather than a list, so it is unset rather than filtered. An
      # anon account has no business writing into anyone else's npm prefix, and
      # leaving it set would both name the operator and point npm at a directory
      # this account cannot write.
      case ''${NPM_CONFIG_PREFIX-} in
        "$HOME" | "$HOME"/*) ;;
        /home/*) unset NPM_CONFIG_PREFIX ;;
      esac

      unset -f _anon_filter_path_list
      unset _anon_var
    ''
    # APPENDED, NOT INTERPOLATED, and the difference is not style: an
    # interpolation at the start of a line inside an indented string resets what
    # Nix strips from EVERY line of it, so injecting this in place re-indented the
    # whole rendered profile. Concatenating two indented strings keeps each one's
    # stripping to itself.
    + lib.optionalString cfg.browser.enable ''

      # THE BROWSER'S SESSION SERVER, AS A UNIX SOCKET. Not a preference: this
      # account cannot reach loopback at all (anonctl's closure ends in
      # `meta skuid <uid> ip daddr 127.0.0.0/8 drop`), so webhands' default TCP
      # session server starts, reports healthy, and is unreachable from the very
      # verbs it exists to serve. webhands 0.8.0 reads this variable and listens
      # on a socket instead; the endpoint file then carries the transport, so no
      # VERB needs a flag and a plain `webhands serve` is correct here.
      #
      # $HOME-RELATIVE ON PURPOSE. This file is ONE declared file shared by every
      # slot, so the path must not name an account; each session expands it to its
      # own home, which is 0700, and the socket itself is created 0600 by webhands
      # because ownership plus mode IS the access control for a unix socket.
      export WEBHANDS_SOCKET="$HOME/.webhands/session.sock"

      # THE DECLARED BROWSER, NAMED HERE SO A SESSION CAN SEE IT. The wrapper on
      # the webhands binary already sets this, so functionally this line is a
      # duplicate. It exists because the first live session proved the
      # DECLARATION IS INVISIBLE FROM INSIDE: that session looked at
      # ~/.cache/ms-playwright, found it empty (correctly, since nothing was ever
      # downloaded), and concluded it needed `npx playwright install`, which here
      # is ~150 MB across the jail into a directory the wrapper does not read. It
      # stopped only because it happened to be asking about something else.
      #
      # So the fact is put where the session looked: `env`. The second gain is
      # the better one. A stray install now fails LOUDLY against a read-only
      # store path instead of quietly spending a long download on nothing.
      #
      # THE VALUE IS DERIVED, never spelled, so this and the wrapper cannot drift
      # into naming different browsers.
      #
      # THIS IS NOT THE BOX-WIDE VARIABLE hosts/telemaque/default.nix refuses.
      # That refusal protects the eight template-tree repos whose
      # @playwright/test pins a DIFFERENT Playwright, and those are the
      # operator's; an anon slot has no such repo and no such pin. The
      # distinction is asserted rather than left to this comment.
      export PLAYWRIGHT_BROWSERS_PATH="${cfg.browser.package.browsers}"
    ''
    + ''

      # No identity, no credential, and nothing that phones home. An anon shell is
      # deliberately boring.
      :
    '';

  # Per-account rules. Group == account name: modules/anon-accounts.nix declares
  # a dedicated group per slot so nothing is group-shared with the operator.
  rulesFor = account: let
    home = "/home/${account}";
    agentDir = "${home}/.pi/agent";
    g = account;
  in
    [
      "d ${home}/.pi 0700 ${account} ${g} -"
      "d ${agentDir} 0700 ${account} ${g} -"
      # `Z` with a `-` mode corrects OWNERSHIP recursively without touching the
      # modes the `d` lines above just set. `d` alone does not chown a directory
      # that already exists, which is how the operator's .agents tree ended up
      # root-owned; an anon home that pi cannot write is the same bug wearing a
      # different hat.
      "Z ${home}/.pi - ${account} ${g} -"

      "L+ ${agentDir}/models.json - - - - ${config.environment.etc."anon-home/models.json".source}"
      "L+ ${agentDir}/settings.json - - - - ${config.environment.etc."anon-home/settings.json".source}"
      "L+ ${agentDir}/AGENTS.md - - - - ${cfg.agentsFile}"
    ]
    # webveil.json at the HOME ROOT, not under .pi: it is read by the webveil
    # CLI as well as by the pi extension, and webveil resolves it by walking UP
    # from the session's cwd. The home root is the highest point that walk can
    # reach while still being this account's own, so it is the one placement
    # that works from the home and from any directory beneath it.
    ++ lib.optionals cfg.webTools.enable [
      "L+ ${home}/webveil.json - - - - ${config.environment.etc."anon-home/webveil-${account}.json".source}"
    ]
    ++ lib.optionals cfg.loginEnv [
      "L+ ${home}/.bash_profile - - - - ${config.environment.etc."anon-home/bash_profile".source}"
    ]
    # THE BROWSER PROFILE, which is a DIRECTORY and never a link. webhands
    # writes a whole Chromium user-data dir in here (cookies, storage, a
    # persona's session), so a read-only store symlink would be the
    # DECLARED-versus-SEEDED trap this module's header describes, one level
    # deeper: the tool would fail at first launch rather than at activation.
    # Every path is derived from THIS account's home, which is what keeps two
    # slots' identically-named profiles apart.
    ++ lib.optionals cfg.browser.enable (
      [
        "d ${home}/.webhands 0700 ${account} ${g} -"
        "d ${home}/.webhands/profiles 0700 ${account} ${g} -"
        "Z ${home}/.webhands - ${account} ${g} -"
      ]
      ++ map (
        profile: "d ${home}/.webhands/profiles/${profile} 0700 ${account} ${g} -"
      )
      cfg.browser.profiles
    )
    ++ lib.optionals (cfg.skills != {}) (
      [
        "d ${home}/.agents 0700 ${account} ${g} -"
        "d ${home}/.agents/skills 0700 ${account} ${g} -"
        "Z ${home}/.agents - ${account} ${g} -"
      ]
      ++ lib.mapAttrsToList (
        name: path: "L+ ${home}/.agents/skills/${name} - - - - ${path}"
      )
      cfg.skills
    );
in {
  options.nixos-modules.anonHome = {
    enable = lib.mkEnableOption ''
      declared, credential-free HOME CONTENT for anonctl's anon accounts.

      Pairs with nixos-modules.anonAccounts, which declares the passwd slots this fills.
      Declares files only: anonctl still owns the forcing, the ledger and the
      LAN exemption, and nothing here runs anonctl
    '';

    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.attrNames config.nixos-modules.anonAccounts.accounts;
      defaultText = lib.literalExpression "lib.attrNames config.nixos-modules.anonAccounts.accounts";
      description = ''
        Which anon accounts get this home. DERIVED from nixos-modules.anonAccounts by
        default, and that default is the one worth using: a slot that exists
        without a home is the "No models available" state this module was
        written to end, and two hand-maintained lists of account names would
        drift silently in exactly that direction. Declaring the pool in one
        commit (see modules/anon-accounts.nix on why) then gives every slot a
        home in the same commit.
      '';
    };

    provider = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = ''
        WASISABI: the provider id the sessions use when `endpoint` is null, i.e.
        the name an EXTENSION registers the model under (pi-wasisabi-local
        registers the machine's own model server as "local"). Ignored when
        `endpoint` is set, which renders its own provider into models.json.
      '';
    };

    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.1.150:8080";
      description = ''
        The LAN model server as an EXACT `IP:port`, used to build the
        credential-free baseUrl.

        RAW IP AND MANDATORY PORT, enforced by an assertion rather than asked
        for politely, and the form is not cosmetic. A hostname would be a
        hijackable redirect for AI traffic (a poisoned name points model calls,
        which carry prompt content, at someone else's endpoint) and this is
        precisely the traffic that must not be redirected. The same literal is
        also what anonctl's `--allow` takes: it refuses hostnames and
        port-omitted values outright (its ADR-0007), because a bare IP exemption
        opens every port on that host, which deanonymizes the account the moment
        that host runs a forwarding proxy. So this option and the exemption
        speak the SAME grammar, and the literal set here is the literal passed
        to the exemption, e.g. for 192.168.1.150:8080:

          sudo anonctl update <account> --endpoint socks5h://127.0.0.1:9050 \
            --allow 192.168.1.150:8080

        THIS MODULE CANNOT CREATE THAT HOLE. Declaring an endpoint here only
        writes a config file naming it; until the exemption above is applied,
        a session's connection to it is redirected into the shim like any other
        and the model is simply unreachable. That asymmetry is deliberate: a
        deploy must never be able to punch a hole in a jail.
      '';
    };

    webTools = {
      enable = lib.mkEnableOption ''
        the `web_search` / `web_fetch` pair in every anon home, by delivering the
        pi-webveil extension FROM THE STORE and declaring a `webveil.json` that
        points at this account's own search socket (ADR-0017).

        OFF BY DEFAULT, so an anon home stays exactly what it was until a host
        asks for this. Turning it on changes what an anon session can reach
        and is therefore a host decision, not a module default
      '';

      package = lib.mkOption {
        type = lib.types.package;
        example = lib.literalExpression "self.packages.\${system}.pi-webveil";
        description = ''
          The pi-webveil package, taken from the STORE rather than installed
          from npm at session start.

          WHY THE STORE. pi installs `packages` entries from npm when a session
          starts. For an anon account every such fetch crosses the jail (npm
          over Tor), which is slow, observable, and can fail closed, leaving a
          session with no web tools. A store path makes session start fully
          offline and makes the extension version-pinned and rollback-covered
          like every other tool on the box. That pi ACCEPTS an absolute store
          path is measured, not assumed: see
          work/notes/findings/pi-loads-store-path-extensions-and-uwsgi-socket-activation-needs-fd3.md.

          The exact path handed to pi comes from the package's own
          `extensionSubdir` passthru, never spelled here, because the failure
          mode for a wrong subpath is SILENCE: pi's local resolution is a bare
          `if (!existsSync(resolved)) return;`, so a typo costs the account its
          web tools with no warning, no error and exit 0. An assertion below
          rejects a package that does not publish that passthru.
        '';
      };

      searchSocketPaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = lib.genAttrs cfg.accounts (account: "/run/anon-search/${account}/search.sock");
        defaultText = lib.literalExpression ''lib.genAttrs cfg.accounts (a: "/run/anon-search/''${a}/search.sock")'';
        description = ''
          READ-ONLY: where each account's own SearXNG serves, as a unix socket
          path, and therefore what that account's `webveil.json` names as its
          backend. Exposed as an attrset so modules/anon-search.nix and this
          module cannot disagree about the path; whoever serves it reads this
          rather than restating it.

          A UNIX SOCKET IS NOT A CHOICE OF STYLE HERE. An anon account cannot
          serve a loopback TCP port at all: anonctl's closure ends in
          `meta skuid <anon> ip daddr 127.0.0.0/8 drop`, and an inbound
          connection's REPLY packets carry the listening socket owner's uid, so
          the SYN arrives and the SYN-ACK is dropped. A unix socket is not IP
          traffic and traverses no nftables chain. Measured: see
          work/notes/findings/anon-uid-cannot-serve-inbound-tcp-the-reply-is-dropped.md.

          IN /run, NOT IN THE HOME, amending ADR-0017's "a socket in that
          account's home" after building it. Three reasons, none of them
          security: /run is a tmpfs, so a stale socket cannot outlive a reboot
          (RemoveOnStop covers a clean stop but not a crash or a power cut, so
          this makes it structural rather than best-effort); the account's home
          stays PURELY this module's declared content, instead of having another
          module write into a directory this one owns, which matters because the
          wherever instance will want the same treatment; and nothing that walks
          a home (a backup, a sync, a plain `ls`) trips over a socket.

          SECURITY IS UNCHANGED BY THE MOVE, which is why it was safe to make:
          `connect()` needs write permission on the socket inode, so
          `SocketMode=0600` plus `SocketUser=<account>` is the whole gate, and
          the per-account parent directory is created 0700 and account-owned so
          the defence-in-depth the 0700 home used to provide is preserved
          exactly. modules/anon-search.nix owns that tmpfiles rule, next to the
          socket unit that depends on it.
        '';
      };
    };

    models = lib.mkOption {
      description = ''
        The models the endpoint serves. There is NO credential field in this
        schema, by design: see the allowlist section of the module header.
        Ids must be what the server advertises at /v1/models (the router's
        canonical names), so a client that lists sees what it can select.
      '';
      default = [];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            description = "Canonical model id as the server advertises it.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            description = "Display name in pi's picker.";
          };
          reasoning = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the model emits reasoning content.";
          };
          contextWindow = lib.mkOption {
            type = lib.types.ints.positive;
            default = 262144;
            description = "Context window in tokens.";
          };
          maxTokens = lib.mkOption {
            type = lib.types.ints.positive;
            default = 8192;
            description = "Maximum output tokens.";
          };
          vision = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether the model accepts image input. Declared honestly rather
              than flattened to text-only: pi offers image attachment only for
              a model whose `input` says so, and silently dropping the
              capability would make an anon session look like the model was
              broken.
            '';
          };
        };
      });
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      description = ''
        Which of `models` a session starts on. Asserted to be one of them:
        settings.json is a read-only store symlink here, so a session CANNOT
        correct a bad default from the UI and would start on a model that does
        not exist.

        THIS IS ENFORCED BY ORDERING, not merely written into settings.json,
        because pi picks the first entry of `enabledModels` BEFORE it consults
        the declared default (its `findInitialModel` step 2 shadows step 3; the
        full order is documented at `orderedModels` above). The module emits the
        declared default first in both rendered files, so this option decides the
        startup model however `models` happens to be ordered, and a reordering
        of that list cannot silently change which model a session opens on.
      '';
    };

    operatorAgentsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if config.nixos-modules.piUser.enable
        then config.nixos-modules.piUser.agentsFile
        else null;
      defaultText = lib.literalExpression "config.nixos-modules.piUser.agentsFile, when piUser is enabled";
      description = ''
        The OWNER's AGENTS.md, which `agentsFile` is refused for being: that
        file describes its owner, and linking it into an anon home would put
        that identity in every anon session's context. Set it when the owner's
        pi is configured by something other than nixos-modules.piUser.
      '';
    };

    agentsFile = lib.mkOption {
      type = lib.types.path;
      default = ./anon-home/AGENTS.md;
      defaultText = lib.literalExpression "./anon-home/AGENTS.md";
      description = ''
        The user-global AGENTS.md every anon session loads.

        NOT THE OPERATOR'S FILE, and that is the whole point of the separate
        default. hosts/telemaque/home/.pi/agent/AGENTS.md is a portrait of the
        operator: it names their home directory layout, their repositories,
        their worktree convention, their box names, their printer and their
        systemd unit, and its instructions assume credentials, git remotes and
        push rights an anon account deliberately does not have. Linking it here
        would put the operator's identity into the context window of every anon
        session, which is the single most direct way this module could fail.

        SHARED ACROSS SLOTS AND HOSTS rather than per host, because it is the
        standing instruction set for "an anon account", a role that does not
        vary by machine. It lives beside this module for that reason instead of
        under hosts/<host>/home/.

        DECLARED, not seeded, exactly as nixos-modules.piUser.agentsFile is and for
        the same reason: this is policy, and policy that drifts per account
        with no diff and no review is worse than no policy.

        TWO GUARDS APPLY, and they are different. It must be a STORE PATH
        (provenance: refuses a sops secret), AND its CONTENT is scanned at
        evaluation for credential shapes and for the name of any other account
        on this box. The second is the one that matters here: the operator's
        own AGENTS.md is a perfectly good store path, so provenance alone would
        happily link the file this option exists to keep out.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''
        {inherit (pkgs.somePackage.passthru) someCredentialFreeSkill;}
      '';
      description = ''
        Agent skills to link into ~/.agents/skills, as name -> store path.

        EMPTY BY DEFAULT, which is a decision and not laziness: a skill tree is
        read straight into an agent's context and its CONTENT is not scanned
        (see the module header), so every addition is an explicit, named,
        store-path-checked act. What it is NOT is a statement that the
        operator's own set (hosts/telemaque/default.nix) is wholesale wrong.
        Item by item:

          - dorfl's sixteen are work/-protocol skills. They instruct an agent to
            claim tasks, commit, open and merge PRs. An anon account has no git
            identity, no forge credential and no repository, so they are at best
            inert and at worst a standing instruction to do the exact things
            this module's AGENTS.md forbids. OUT, with the caveat that some of
            them need only a COMMIT rather than a push, so the set is not
            uniformly inapplicable and is worth revisiting deliberately.
          - reconcile-template-tree operates on the operator's template tree,
            and print-doc drives a physical printer, which is a location and is
            the operator's. OUT, permanently.
          - accommodation-hunt is real-world identity by construction. OUT.
          - the credential-free, machine-local ones (diagnosing-bugs, tdd,
            codebase-design, writing-for-agents, prototype, grilling, research,
            use-webhands) are IN: they change how a session works, not who it
            is.

        USE-WEBHANDS IS IN, AND THE OBJECTION RECORDED HERE BEFORE WAS FALSE.
        It said the skill "drives a browser the OPERATOR is logged into. Handing
        that to an anon session does not leak an identity, it USES one." That
        does not survive contact with this box: the operator's home is 0700 and
        the unit that hosts these sessions runs ProtectHome=tmpfs with only the
        account's own home bound, so an anon session cannot reach the operator's
        browser profile and, in a hosted session, that profile does not exist in
        the filesystem view at all. webhands resolves its profile under $HOME
        (~/.webhands/profiles/<name>), so a slot drives ITS OWN profile because
        of where its home is, not because anything asked it to.

        THE REAL CONSIDERATIONS, which replace that one:

          - A BROWSER IS NOT BUNDLED. webhands ships no binary and Playwright
            would download a ~150 MB one per account, over Tor, into undeclared
            state. The `browser` option below is the answer: one declared
            executable, wrapped into the CLI itself, shared with the operator.
            Without it the skill describes verbs that fail at the first launch.
          - A LOGIN IS HEADED, AND THIS BOX HAS NO DISPLAY. `setup-profile`
            opens a visible window, which a jailed account on a headless machine
            cannot produce. The default here is scoped to the HEADLESS verbs
            (serve, snapshot, extract, eval), which need only a profile
            DIRECTORY, and that is declared. Minting a persona is an
            operator-driven act with a forwarded display, documented rather than
            automated.
          - A PERSONA BELONGS TO ONE SLOT (docs/adr/0021). The profile a slot
            logs in with is that slot's identity, and the homes are 0700 so the
            structure agrees with the instruction.
          - FINGERPRINT, twice over, and both are accepted rather than solved.
            A vanilla Chromium over Tor is far more fingerprintable than Tor
            Browser: this is adequate against "not attributable to the operator"
            and is NOT "anonymous against a determined cross-site correlator".
            It is stated in the AGENTS.md too, because the session's user is who
            needs to know.

        AND THE MODULE HEADER'S ARGUMENT, ANSWERED RATHER THAN IGNORED: an
        identical skill set across slots IS a shared behavioural signature. It
        is accepted, because it changes nothing that is not already true (every
        slot shares one AGENTS.md, one model list and one home layout, which are
        far stronger tells than a skill directory) and because the alternative
        is not "vary the skills" but "vary the instructions and the model",
        which this module deliberately does not offer. The property this
        arrangement actually provides is unlinkability from the OPERATOR, which
        no skill affects; unlinkability BETWEEN slots is weak by construction
        and is not improved by giving one slot a different reading list.
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = {};
      example = lib.literalExpression ''
        {memonaut-pi = self.packages.''${system}.memonaut-pi;}
      '';
      description = ''
        Extra pi extensions for every anon home, as name -> PACKAGE, delivered
        from the store exactly as webTools delivers pi-webveil (ADR-0017).

        THE NAME IS DOCUMENTATION ONLY; what is rendered into settings.json is
        `''${package}/''${package.extensionSubdir}`, so the package must publish
        that passthru and an assertion below refuses one that does not. The
        reason is the same silent failure pi-webveil's own package header
        records: pi skips a `packages` entry whose path does not exist with no
        warning, no error and exit 0, so a wrong subpath costs an account its
        tools while looking exactly like an account that has them.

        WHY THIS IS NOT JUST webTools WITH MORE ENTRIES: webTools also renders a
        per-account webveil.json naming that account's own search socket, so it
        is a feature rather than a list. This option is the list.

        WHAT BELONGS HERE is an extension that is credential-free, needs no
        network at load, and reads only what the ACCOUNT can already read. The
        worked example is memonaut-pi, and it is worth stating why it qualifies,
        because the obvious reading is that a transcript searcher is exactly the
        wrong thing to hand an anon session: its index is
        `~/.local/share/memonaut/index.db`, per-HOME and 0600 (measured on this
        box), so a slot indexes its own sessions and cannot reach the
        operator's, which is 0700 away and, in a hosted session, not in the
        filesystem view at all. An extension that read a SHARED index would be
        refused on the same facts.
      '';
    };

    browser = {
      enable = lib.mkEnableOption ''
        a browser for every anon home: a declared profile directory per slot,
        driven with the `webhands` CLI whose package carries the one browser
        executable this repo declares (ADR-0022).

        WHAT THIS OPTION ACTUALLY PLACES is a DIRECTORY, and that is the whole
        trick. The binary reaches the account through the system profile, and
        the browser reaches the binary through webhands' own wrapper, so neither
        is per-account and neither is declared here. What IS per-account is the
        profile, which webhands resolves under $HOME and refuses to create on a
        headless launch (a missing profile is a typed error, so a typo cannot
        silently spawn a blank one). Declaring the directory is what removes the
        need for the headed `setup-profile` flow, which has no display to open a
        window on here.

        THE SESSION SERVER IS A UNIX SOCKET HERE, AND THAT IS NOT OPTIONAL.
        webhands drives its browser from a long-lived `serve` process that each
        verb connects to, and until 0.8.0 that connection was LOOPBACK TCP,
        which an anon uid cannot use: anonctl's closure ends in
        `meta skuid <uid> ip daddr 127.0.0.0/8 drop`, the same rule ADR-0017 put
        the per-account SearXNG on a unix socket for. Measured on this box:
        `serve` reported healthy on 127.0.0.1 and every verb failed to reach it,
        with a curl to the same port TIMING OUT rather than being refused, which
        is the kernel drop rather than a dead server.

        webhands 0.8.0 serves over a socket instead (`--socket`, or
        `WEBHANDS_SOCKET`), and the endpoint file then carries the transport, so
        VERBS NEED NO FLAG. This module therefore exports that variable in the
        declared login profile rather than asking a session to remember a flag:
        a plain `webhands serve` is socket mode for an anon account, which is
        what the shipped use-webhands skill documents. Two consequences worth
        naming: `browser.enable` requires `loginEnv` (asserted below), because
        the profile is how the default travels; and the package must be 0.8.0 or
        later (also asserted), because an older one ignores both the flag and
        the variable and falls back to a TCP port nothing in the account can
        reach, silently.

        THE SOCKET LIVES IN THE HOME, not in /run, which is the opposite of
        where ADR-0017 put the search socket. The reasons that moved that one do
        not apply here: a stale socket cannot accumulate because webhands
        unlinks one before binding and removes it on stop (and refuses a path
        that exists and is not a socket); nothing walks or synchronises an anon
        home (`no anon path reaches syncthing` is an evaluated claim); and the
        endpoint file that advertises it is in `~/.webhands` already, so putting
        the socket elsewhere would split one lifecycle across two owners. The
        path is spelled `$HOME`-relative, so ONE declared profile serves every
        slot and no account name is needed to write it.

        HOSTED DASHBOARD SESSIONS GET THE SAME BROWSER, through
        modules/wherever-anon.nix rather than through this module: that unit
        declares its environment explicitly and never reads the login profile,
        so it derives WEBHANDS_SOCKET (from `socketPaths` below) and
        PLAYWRIGHT_BROWSERS_PATH (from the package's `browsers`) itself, and
        puts this package on its PATH. It could not before, because Chromium
        died under that unit's SystemCallFilter allowlist; the measured fix
        (allow capset, deny with EPERM) is recorded at that unit and in
        work/notes/findings/chromium-dies-under-a-systemcallfilter-allowlist.md
      '';

      package = lib.mkOption {
        type = lib.types.package;
        example = lib.literalExpression "self.packages.\${system}.webhands";
        description = ''
          The webhands package, whose wrapper carries the declared browser.

          TAKEN AS A PACKAGE RATHER THAN A BOOLEAN so this module can ASSERT
          that the browser exists: the package must publish a `browsers`
          passthru, which packages/webhands.nix sets to the bundle it wrapped
          the binary with. Without that assertion, a webhands built without a
          browser would place a profile directory, put a working-looking CLI on
          the account's path, and fail at the first launch with
          `missing-browser-binary` and an instruction to download 150 MB over
          Tor, which is the exact outcome the declaration exists to prevent.

          NOTE WHAT THIS MODULE DOES NOT DO WITH THE PACKAGE: it does not add it
          to any PATH. The binary is on the account's path because the HOST
          installs it box-wide, which is also what makes the executable shared
          with the operator rather than duplicated per slot. (The wherever-anon
          unit, which sees no box-wide profile, puts this same package on its
          own PATH.)
        '';
      };

      socketPaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = lib.genAttrs cfg.accounts (account: "/home/${account}/.webhands/session.sock");
        defaultText = lib.literalExpression ''lib.genAttrs cfg.accounts (a: "/home/''${a}/.webhands/session.sock")'';
        description = ''
          READ-ONLY: where each account's webhands session server listens, as a
          unix socket path. Exposed so a check and a future consumer read the
          same value this module writes, rather than restating it.

          THE LOGIN PROFILE DOES NOT USE THESE STRINGS, and that is deliberate
          rather than an oversight: it exports `$HOME/.webhands/session.sock`,
          which is the same path for every account without naming one, so a
          single declared file serves the whole pool. These absolute forms exist
          for whoever needs to speak about a specific slot's socket from
          outside it.
        '';
      };

      profiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["default"];
        description = ''
          Which profile directories to declare in each account's own home.

          `default` is webhands' own default profile name, so the plain verbs
          work with no flag. More than one is for a slot that wants separate
          browser identities (a logged-in persona and a clean one); they cost an
          empty directory each until something launches against them.

          ONE NAMESPACE PER ACCOUNT, NEVER SHARED. Each path is built from the
          account's own home, and the homes are 0700 with a per-account group,
          so slot A cannot read slot B's cookies even though both are called
          `default`. An eval claim pins that derivation, because a profile root
          hoisted to a shared location is precisely the change that would look
          like tidying.
        '';
      };
    };

    loginEnv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Declare ~/.bash_profile for the account.

        The ANSWER TO "is the anon PATH sane?" is yes, and this option is not
        about that. anonctl's `use` hands the session
        PATH=/usr/local/bin:/usr/bin:/bin and leaves the refinement to a profile
        drop-in it writes only for accounts it CREATED -- which an adopted
        account, i.e. every account on this box, never gets. NixOS covers it
        anyway: /etc/profile sources set-environment, which OVERWRITES PATH with
        an absolute list carrying /run/current-system/sw/bin, so a login shell
        finds pi and anonctl. No host declaration is needed to make the account
        WORK.

        What this corrects is that the box-wide environment spells the
        operator's home in TEN variables, not just PATH: the profile-derived
        list (PATH, GTK_PATH, INFOPATH, LIBEXEC_PATH, QTWEBKIT_PLUGIN_PATH,
        TERMINFO_DIRS, XCURSOR_PATH, XDG_CONFIG_DIRS, XDG_DATA_DIRS,
        NIX_PROFILES) plus NPM_CONFIG_PREFIX. All unreachable from here, since
        that home is 0700, and all of them the operator's name sitting in an
        anon session's environment one `env` away from an agent's context.

        The file filters foreign /home entries out of those lists, unsets
        NPM_CONFIG_PREFIX, and touches nothing else. It is a MITIGATION: the
        root fix is that operator-specific prefixes should not be box-wide, and
        that change belongs to the modules that declare them.

        KNOW WHAT DECLARING THIS FILE COSTS: bash reads the FIRST of
        ~/.bash_profile, ~/.bash_login, ~/.profile, so declaring this one makes
        the other two dead letters for the account, and a login shell still
        does not read ~/.bashrc. Nothing in this fleet writes any of them for an
        anon account today, and /etc/bashrc is still reached through
        /etc/profile, so the practical loss is nil; it stops being nil the day a
        session writes ~/.bashrc and wonders why a login shell ignores it.

        Turn it off if the account's shell environment should be whatever the
        system hands it, unmodified.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ONE definition of environment.etc, not several: the per-account webveil
    # files are computed, so they have to merge with the fixed ones here rather
    # than in a second `environment.etc = ...` (which the module system would
    # reject as a duplicate definition of the same attribute).
    environment.etc =
      {
        "anon-home/models.json".text = builtins.toJSON modelsJson;
        "anon-home/settings.json".text = builtins.toJSON settingsJson;
        "anon-home/bash_profile" = lib.mkIf cfg.loginEnv {text = bashProfile;};
      }
      # One webveil config per account, because each names that account's OWN
      # socket. The slot name appears in the store path, which is the
      # declared-versus-observed rule ADR-0017 records: a declared slot exists
      # whether or not anyone uses it, so naming it reveals nothing, while
      # anything saying WHICH slots are in use, when, or by whom stays off the
      # store entirely.
      // lib.optionalAttrs cfg.webTools.enable (lib.listToAttrs (map (account:
        lib.nameValuePair "anon-home/webveil-${account}.json" {
          text = builtins.toJSON (webveilJsonFor account);
        })
      cfg.accounts));

    systemd.tmpfiles.rules = lib.concatMap rulesFor cfg.accounts;

    assertions =
      [
        {
          assertion = config.nixos-modules.anonAccounts.enable;
          message = ''
            nixos-modules.anonHome is enabled but nixos-modules.anonAccounts is not. This module fills
            homes that module declares: without it the accounts are undeclared,
            and on a `users.mutableUsers = false` host NixOS deletes them at
            every activation, so these tmpfiles rules would be writing into the
            home of an account that is about to stop existing.
          '';
        }
        {
          assertion = lib.all (a: config.nixos-modules.anonAccounts.accounts ? ${a}) cfg.accounts;
          message = ''
            nixos-modules.anonHome.accounts names an account nixos-modules.anonAccounts does not
            declare: ${lib.concatStringsSep ", " (lib.filter (a: !(config.nixos-modules.anonAccounts.accounts ? ${a})) cfg.accounts)}.
            That would create /home/<name> content owned by a uid nothing pins,
            which is the orphaned-state failure modules/anon-accounts.nix exists
            to prevent, reached from the filesystem side.
          '';
        }
        {
          # Same grammar anonctl's ADR-0007 enforces for `--allow`, checked here
          # so the declared baseUrl and the imperative exemption cannot disagree
          # about what the endpoint IS.
          #
          # PRIVATE RANGES ONLY, which is stricter than "parses as IPv4" and is
          # the difference between this assertion being true and merely looking
          # true. A plain IPv4 check accepts 203.0.113.5:443, i.e. a PUBLIC
          # provider, which this module's header claims it cannot name; it also
          # accepts 100.64.0.0/10 tailnet addresses, which anonctl's own
          # guardrail REFUSES (hosts/shyrka/default.nix records that), so the
          # two would disagree in exactly the direction the comment promises
          # they cannot. An anon home may name a LAN model server and nothing
          # else.
          assertion = cfg.endpoint == null || endpointOk;
          message = ''
            nixos-modules.anonHome.endpoint must be an exact PRIVATE or LOOPBACK
            IPv4 `IP:port`, got "${toString cfg.endpoint}". Accepted: 10.0.0.0/8,
            172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, with a port in 1-65535.

            A hostname is a hijackable redirect for traffic that carries prompt
            content; a port-omitted value is what anonctl refuses for `--allow`
            because it opens every port on that host; a PUBLIC address would be
            a remote provider, which is not a thing an anon home is allowed to
            name; and a 100.64/10 tailnet address is refused by anonctl's own
            guardrail, so declaring one here would produce a config file naming
            an endpoint the exemption can never be written for.
          '';
        }
        {
          assertion = cfg.models != [];
          message = ''
            nixos-modules.anonHome.models is empty, so settings.json would carry an empty
            enabledModels and pi would warn "No models available" -- the exact
            symptom this module exists to fix, reproduced by deploying it.
          '';
        }
        {
          # The ONE thing that cannot be checked later. pi resolves a local
          # `packages` entry with a bare `if (!existsSync(resolved)) return;`:
          # a path that does not exist produces NO warning, NO error and exit 0,
          # in a real session as well as under --help, so the account simply has
          # no web_search and no web_fetch and nothing says so. (A path that
          # exists but is not a loadable package IS reported by a session, so
          # that case needs no help from us.)
          #
          # This cannot be an eval-time `pathExists` on the store path, because
          # the output does not exist until it is built and the assertion would
          # fire on every clean eval. Instead the package PUBLISHES the subdir
          # and asserts at BUILD time that it is populated, and this checks that
          # we were handed such a package rather than an arbitrary one.
          assertion = !cfg.webTools.enable || cfg.webTools.package ? extensionSubdir;
          message = ''
            nixos-modules.anonHome.webTools.package does not publish `extensionSubdir`, so
            the path handed to pi would have to be spelled by hand here.

            That is refused rather than guessed because the failure is SILENT:
            pi skips a `packages` entry whose path does not exist without a
            warning, an error or a non-zero exit, so a wrong subpath yields an
            anon session with no web_search and no web_fetch that is
            indistinguishable from a working one until someone asks it to search.

            Pass the repo's pi-webveil package (self.packages.''${system}.pi-webveil),
            which publishes the subdir and asserts at build time that it holds a
            package.json, the pi.extensions entry point and the bundled webveil.
          '';
        }
        {
          assertion = lib.any (m: m.id == cfg.defaultModel) cfg.models;
          message = ''
            nixos-modules.anonHome.defaultModel is "${cfg.defaultModel}", which is not one
            of nixos-modules.anonHome.models (${lib.concatMapStringsSep ", " (m: m.id) cfg.models}).
            settings.json is a read-only store symlink in an anon home, so a
            session cannot pick a working model to replace a broken default.
          '';
        }
        {
          # Redundant while the schema below has no credential field, and kept
          # anyway: it is the assertion that would catch a future "just add an
          # apiKey option" change, which is precisely the change that would
          # look harmless in review.
          assertion = lib.all (p: p.apiKey == "none") (lib.attrValues modelsJson.providers);
          message = ''
            nixos-modules.anonHome renders a models.json whose apiKey is not "none". An
            anon account authenticates to nothing: an endpoint that wants a
            credential is an endpoint that can attribute the account, and the
            key itself would land in the world-readable Nix store.
          '';
        }
        {
          assertion = !agentsFileIsOperators;
          message = ''
            nixos-modules.anonHome.agentsFile is byte-identical to the operator's own
            AGENTS.md (nixos-modules.piUser.agentsFile). That file is a portrait of
            the operator: their home layout, repositories, worktree convention,
            box names, hardware, and instructions that assume credentials and
            push rights an anon account deliberately does not have. Linking it
            here would put the operator's identity into the context window of
            every anon session.

            This is checked by CONTENT EQUALITY rather than by the credential
            scan because that file contains no username and no credential shape
            at all, so the scan cannot see it. Point this option at a
            purpose-written anon policy file; the module's default is one.
          '';
        }
        {
          assertion = isStorePath cfg.agentsFile;
          message = ''
            nixos-modules.anonHome.agentsFile must be a STORE path, got
            "${cfg.agentsFile}". This is the module's credential guard, not a
            style rule: a sops secret is the string "/run/secrets/<name>"
            (decrypted at activation, never rendered into the store), so
            anything outside the store may be a secret and is refused. Use a
            repo-relative path literal, which Nix copies into the store.
          '';
        }
      ]
      ++ lib.mapAttrsToList (name: p: {
        # Same contract as webTools.package, for the same silent failure: an
        # extension whose path does not exist is skipped by pi with no warning,
        # no error and exit 0.
        assertion = p ? extensionSubdir;
        message = ''
          nixos-modules.anonHome.extensions."${name}" does not publish `extensionSubdir`,
          so the path handed to pi would have to be spelled by hand.

          That is refused rather than guessed because the failure is SILENT: pi
          skips a `packages` entry whose path does not exist without a warning,
          an error or a non-zero exit, so a wrong subpath yields an anon session
          missing a whole tool surface and indistinguishable from a working one.

          Pass a package that publishes the subdir and asserts at build time
          that it is populated, as packages/pi-webveil.nix and
          packages/memonaut-pi.nix both do.
        '';
      })
      cfg.extensions
      ++ lib.optional cfg.browser.enable {
        # The browser is not something this module PLACES, so this is the only
        # point at which its absence can be caught at all. Without it the
        # failure surfaces as `missing-browser-binary` inside a jailed account,
        # with a fix instruction that would download ~150 MB over Tor.
        assertion = cfg.browser.package ? browsers;
        message = ''
          nixos-modules.anonHome.browser.package does not publish `browsers`, so it carries
          no declared browser executable and this module would place a profile
          directory for a CLI that cannot launch anything.

          Pass the repo's webhands package (self.packages.''${system}.webhands),
          which wraps the binary with PLAYWRIGHT_BROWSERS_PATH pointing at the
          one browser this repo declares (packages/playwright-browsers.nix,
          ADR-0022) and publishes that bundle as `browsers`.
        '';
      }
      ++ lib.optional cfg.browser.enable {
        # THE VERSION FLOOR, and it guards a SILENT failure. Before 0.8.0
        # webhands could only serve on a loopback TCP port, which an anon uid
        # cannot reach; an older build ignores both `--socket` and
        # WEBHANDS_SOCKET, so `serve` would report ok on 127.0.0.1 and every
        # verb would fail to reach a server that is alive and healthy. Nothing
        # about the declaration would look wrong.
        assertion = lib.versionAtLeast cfg.browser.package.version "0.8.0";
        message = ''
          nixos-modules.anonHome.browser.package is webhands ${cfg.browser.package.version},
          and an anon home needs 0.8.0 or later: that is the release whose
          `serve` can listen on a UNIX SOCKET (`--socket` / WEBHANDS_SOCKET).

          An anon account cannot reach loopback at all, because anonctl's
          closure ends in `meta skuid <uid> ip daddr 127.0.0.0/8 drop`, so an
          older build's TCP session server is unreachable from the verbs it
          serves. The failure is quiet and misleading: `serve` reports ok, the
          browser is running, and every verb says it cannot reach the session
          server.
        '';
      }
      ++ lib.optional cfg.browser.enable {
        assertion = cfg.browser.enable -> cfg.loginEnv;
        message = ''
          nixos-modules.anonHome.browser.enable is on while nixos-modules.anonHome.loginEnv is off.
          The login profile is how the socket path reaches a session
          (WEBHANDS_SOCKET="$HOME/.webhands/session.sock"), so without it a
          plain `webhands serve` falls back to a loopback TCP port this account
          cannot reach, and every verb fails while the server looks healthy.

          Either turn loginEnv on, or drop browser.enable and have sessions pass
          `--socket` by hand on every serve.
        '';
      }
      ++ lib.optionals cfg.browser.enable (map (profile: {
          # Interpolated straight into a tmpfiles path, exactly like a skill
          # name: a space or a `..` would make a malformed rule or a directory
          # outside the account's profile root.
          assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" profile != null;
          message = ''
            nixos-modules.anonHome.browser.profiles contains "${profile}", which is not a
            usable profile directory name. It is interpolated into a
            systemd-tmpfiles rule under the account's own home, so it must match
            [A-Za-z0-9][A-Za-z0-9._-]*: a space or newline makes a malformed
            rule, and a ".." escapes the profile root.
          '';
        })
        cfg.browser.profiles)
      ++ lib.mapAttrsToList (name: path: {
        assertion = isStorePath path;
        message = ''
          nixos-modules.anonHome.skills."${name}" must be a STORE path, got "${path}".
          Same guard as agentsFile: anything outside the store may be a
          decrypted secret, and a skill directory is read straight into an
          agent's context. NOTE this is a PROVENANCE check only: unlike the
          rendered files, a skill tree's CONTENT is not scanned (see the
          module header), which is why the default set is empty.
        '';
      })
      cfg.skills
      ++ lib.mapAttrsToList (name: _: {
        # The name is interpolated straight into a tmpfiles path, so a space,
        # a newline or a `..` would produce a malformed rule or a symlink
        # outside ~/.agents/skills.
        assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
        message = ''
          nixos-modules.anonHome.skills."${name}" is not a usable skill directory name.
          It is interpolated into a systemd-tmpfiles rule and into a path under
          ~/.agents/skills, so it must match [A-Za-z0-9][A-Za-z0-9._-]*: a
          space or newline makes a malformed rule, and a ".." escapes the
          skills directory entirely.
        '';
      })
      cfg.skills
      ++ lib.mapAttrsToList (label: hits: {
        # Guard 2 from the module header: the CONTENT scan. This is the check
        # ADR-0013 requires in place of anonseed's runtime refusal to write a
        # real-looking credential into an anonymized home, and it is strictly
        # stronger, being a build-time impossibility rather than a runtime
        # decision.
        assertion = false;
        message = ''
          nixos-modules.anonHome would place ${label} into an anon home, and it contains
          ${lib.concatMapStringsSep ", " (h: "\"${h}\"") hits}.

          An anon account exists to be unattributable, so an anon home may hold
          no credential-shaped literal and no other account's name. If that hit
          is a username, this is almost certainly the operator's own file
          reaching an anon home (the agentsFile option explains why that is the
          most direct way this module can fail). If it is a credential shape,
          it must not be in the world-readable store at all.

          This is a CONTENT check; passing it is not a statement that the file
          is safe, only that it carries none of the shapes searched for.
        '';
      })
      contentOffenders;
  };
}
