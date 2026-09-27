# shellcheck shell=bash
# scripts/anon-reconcile.sh
#
# RECONCILE: the idempotent function from anonctl's ledger to the on-box state two
# already-built consumers read. It is assembled into a store path by
# packages/anon-reconcile.nix (which supplies the interpreter, `set -euo pipefail`
# and a closed PATH), and wired to a `.path` unit by
# modules/wherever-anon-reconcile.nix. It replaces scripts/anon-provision.sh, which
# did the same work BY HAND for one named account and is deleted.
#
# What it writes, all of it OBSERVED state and therefore outside the Nix store:
#   <state-dir>/<account>/state.json    the four-field contract modules/wherever-anon.nix reads
#   <routes-dir>/<handle>.caddy         the routing fragment the wildcard site glob-imports
#
# EVERY PATH IS AN ARGUMENT, and that is a testability requirement rather than a
# style preference: it is what lets the whole thing be fixture-tested as a
# `runCommand` with a fake ledger, without root and without a live box. The same
# goes for the four external commands (`caddy`, `systemctl`, `nft`, the uid
# lookup): each is injectable, so the REAL code path runs under test with a stub
# standing in only for the privileged bit at the very end.
#
# ---------------------------------------------------------------------------
# THE ENUMERATION SEAM IS THE LEDGER DIRECTORY, AND `anonctl list` IS NOT IT.
# ---------------------------------------------------------------------------
#
# `/etc/anonctl/accounts/<account>.json` (0700 dir, 0600 files, root-only) is one
# record per account anonctl MANAGES, and anonctl's own `add` calls it the ledger:
# it refuses an account that "already manages, read from anonctl's OWN LEDGER, NOT
# from the passwd table". Only the FILENAMES are read here. The contents are not
# parsed, deliberately: their shape is anonctl's business and guessing it is how
# you build something that works on one box and silently misreads another.
#
# `anonctl list --json` is the obvious alternative and is NOT used, though the
# reason changed with anonctl 0.7.0 and the old one must not be repeated. Under
# 0.6.x it was a trap: it enumerated the PASSWD TABLE rather than the ledger (and
# this fleet declares the whole anon POOL in Nix, so every slot is in passwd from
# the first converge, ADDED OR NOT), while printing a `forced` field that
# provision.List never populated, i.e. a Go zero value that read as a verdict.
# 0.7.0 fixed both: the invented verdicts are gone, forcing is an explicit
# tri-state, and a new `managed` field says exactly what this script needs.
# Reading it today would be correct. See
# work/notes/findings/anonctl-list-enumerates-passwd-and-its-forced-field-is-a-zero-value.md
#
# The DIRECTORY stays the seam for a different reason: this is an inotify watcher,
# not a poller. The thing reconcile is triggered BY and the thing it enumerates
# should be the same thing, or the two can disagree about what just happened. A
# ledger file appearing IS the add event; asking a command afterwards is a second
# reading of a world that may have moved again. Filenames are also the narrowest
# dependency available: no output shape to version, and no process per trigger.
#
# ---------------------------------------------------------------------------
# PROVISIONING IS GATED ON PROVEN FORCING, AND A MANAGED-BUT-UNFORCED ACCOUNT IS
# REFUSED LOUDLY RATHER THAN SKIPPED (ADR-0019).
# ---------------------------------------------------------------------------
#
# wherever hosts agent sessions IN-PROCESS, so a session's uid IS the server's uid
# and the kernel forcing is the whole jail. An interface provisioned for an
# account that is not actually forced is the exact "still exists, still looks
# anonymised" failure this feature exists to prevent. So a ledger record alone is
# not enough: it says anonctl MANAGES the account, not that the account is jailed
# right now.
#
# THE GATE IS `anonctl probe`, ANONCTL'S OWN VERB (0.7.0+), not a reimplementation
# here. It answers exactly this question with no network and no Tor exit check:
# the marker is present, its recorded uid IS the account's live uid, and the
# account's nft table is loaded AND funnels that uid into the fail-closed chain.
# Exit 0 only when all three hold, non-zero when any fails OR CANNOT BE
# DETERMINED, which is the direction a gate must fail in.
#
# It replaced a three-part check this script did itself, and the last part of that
# check was WRONG in a way that mattered. Grepping the account's nft table for
# `skuid <uid>` matches the uid ANYWHERE in the table, including inside the
# closure chain's own rules, so a table that is loaded but does not FUNNEL the uid
# into that chain (a partial load, a hand-edit, a base chain flushed on its own)
# passed. Measured on this box with anonctl 0.7.0's own generated ruleset loaded
# into a private network namespace: with the single `meta skuid 8802 jump
# anon_filter` line removed, the table still mentions `skuid 8802` thirteen times,
# the grep says JAILED, and `anonctl probe` says `uid-not-governed`. A false green
# there is an anonymised-looking interface for an account whose traffic is not
# forced, so the coupling to anonctl's internal table naming was not just ugly, it
# was hiding a leak.
#
# THERE IS NO FALLBACK. If probe cannot be run, every managed account is refused.
# A gate with a weaker second opinion is a gate that fails open the moment the
# strong one is unavailable.
#
# A silent skip was rejected: it looks identical to a bug, and the operator would
# be left wondering why `anonctl add` did nothing. The refusal names the account,
# the exact reason and the fix, and reconcile still exits non-zero at the end so
# it shows up in `systemctl --failed` rather than scrolling past.
#
# A refusal SUSPENDS rather than destroys: the routing fragment is retracted and
# the instance stopped (the interface must not stay reachable once the jail stops
# being provable), but the state file is KEPT, so a slot whose forcing lapses and
# returns comes back at the SAME handle and the SAME token. Only a ledger removal
# (`anonctl rm`) destroys state, because that is the signal that the identity is
# gone rather than temporarily unprovable.
#
# ---------------------------------------------------------------------------
# THREE THINGS THAT ARE SHARPER THAN THEY LOOK
# ---------------------------------------------------------------------------
#
# STICKINESS IS CORRECTNESS, NOT TIDINESS. A handle lives in live URLs and a token
# lives in whatever the operator saved, so re-minting either on a routine re-run
# silently breaks a working interface and every session behind it, with a symptom
# (a subdomain that stopped working) that points nowhere near the cause. Handle,
# token and colorway are minted ONCE and then persisted; nothing recomputes them.
#
# A FRAGMENT IS VALIDATED BEFORE IT IS ALLOWED TO REMAIN ON DISK, which is
# stronger than validating before a reload. A running Caddy has already adapted
# its config, so a bad fragment does not disturb it and a reload carrying one
# fails harmlessly. The dangerous case has a long fuse: a bad fragment left on
# disk detonates at the next RESTART or REBOOT, when adaptation fails and Caddy
# does not come up AT ALL, taking every vhost on the machine with it (ADR-0012).
# `adapt`, never `validate`: `validate` fully provisions every module, which means
# opening the access logs under /var/log/caddy, and that fails on permissions and
# would condemn a perfectly good fragment.
#
# A SOCKET-ACTIVATED SLOT THAT REFUSED TO START IS LEFT `failed`, AND WRITING ITS
# STATE DOES NOT REVIVE IT: a failed socket cannot activate. So provisioning ends
# with `reset-failed` + `start` on the socket, unconditionally, because it is
# idempotent and a conditional check would be a race. See
# work/notes/findings/socket-activated-refusal-kills-the-socket-and-on-failure-loops-forever.md

usage() {
  cat <<'EOF'
anon-reconcile [options] [reconcile|links]

  reconcile   (default) make the on-box state match anonctl's ledger: provision a
              wherever interface for every VERIFIED-FORCED account, retract the
              routing of a managed account that is not currently proven forced, and
              tear down an account that has left the ledger.

  links       print one line per provisioned account: account, colorway, handle and
              the full token link. The link IS a credential; the state it reads is
              0600 and account-owned, so this is readable by root only.

Options (every path and every external command is injectable, so the whole script
is fixture-testable without root):

  --ledger-dir DIR     anonctl's ledger, one <account>.json per managed account
                       (default /etc/anonctl/accounts; filenames only, never parsed)
  --marker-dir DIR     anonctl's markers, one <account>.json per VERIFIED account
                       (default /etc/anonctl). WATCHED for change, and read only to
                       decide whether a re-scan is needed: whether an account is
                       jailed is `anonctl probe`'s answer, never this script's
  --anonctl PATH       the anonctl binary whose `probe` verb IS the forced gate
                       (default anonctl from PATH; the unit passes the store path
                       of the build this host declares). Needs root, and never
                       self-elevates: an unprivileged call reports rules-unreadable
                       and is treated as NOT jailed
  --state-dir DIR      per-account state root (default /var/lib/wherever-anon)
  --routes-dir DIR     Caddy fragments the wildcard site glob-imports
                       (default /etc/caddy/anon-routes)
  --routes-group G     group that may READ the fragments, i.e. the group the
                       reverse proxy runs as (default caddy); fragments are 0640,
                       because a fragment maps a handle to a slot's socket path
  --socket-root DIR    where each slot's unit serves (default /run/wherever-anon)
  --palette PATH       the declared colorway palette, as rendered JSON (required)
  --domain NAME        the wildcard site's domain, e.g. telemaque.ska.sh (required)
  --link-scheme S      scheme of the links `links` prints (default https)
  --link-port N        port of the links `links` prints (default: none, i.e. the
                       scheme's own); a local-only dispatcher serves http on a
                       loopback port, which the link has to name
  --caddy PATH         the caddy binary, or `auto` to resolve it from the running
                       caddy unit's ExecStart (default auto)
  --caddy-config PATH  the Caddyfile to adapt, or `auto` to read it from the same
                       unit's ExecStart (default auto)
  --systemctl PATH     systemctl to use (default systemctl)
  --no-chown           skip the chown to the account (fixture runs, which are not
                       root); REFUSES to run against any production path
  --max-passes N       re-scan bound when the ledger changes mid-run (default 4)
  -h, --help           this text

Exit status: 0 reconciled, 2 usage/setup error, 3 reconciled but at least one
managed account was REFUSED (not proven forced).
EOF
}

# --- defaults -------------------------------------------------------------

LEDGER_DIR=/etc/anonctl/accounts
MARKER_DIR=/etc/anonctl
STATE_DIR=/var/lib/wherever-anon
ROUTES_DIR=/etc/caddy/anon-routes
ROUTES_GROUP=caddy
SOCKET_ROOT=/run/wherever-anon
PALETTE=
DOMAIN=
LINK_SCHEME=https
LINK_PORT=
CADDY=auto
CADDY_CONFIG=auto
SYSTEMCTL=systemctl
ANONCTL=anonctl
# Not called here: named only so the preflight can check that `anonctl probe`
# will be able to find it.
NFT_FOR_PROBE=nft
DO_CHOWN=1
MAX_PASSES=4
VERB=reconcile

# Production paths, named once. --no-chown refuses to run against any of them, so
# a fixture cannot write the real /etc, /run or /var/lib even by a typo.
PROD_LEDGER=/etc/anonctl/accounts
PROD_STATE=/var/lib/wherever-anon
PROD_ROUTES=/etc/caddy/anon-routes

REFUSED=0
CHANGED=0

die() {
  echo "anon-reconcile: $*" >&2
  exit 2
}
warn() { echo "anon-reconcile: $*" >&2; }
note() { echo "anon-reconcile: $*"; }

# --- arguments ------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
  --ledger-dir)
    LEDGER_DIR="${2:?--ledger-dir needs a path}"
    shift 2
    ;;
  --marker-dir)
    MARKER_DIR="${2:?--marker-dir needs a path}"
    shift 2
    ;;
  --state-dir)
    STATE_DIR="${2:?--state-dir needs a path}"
    shift 2
    ;;
  --routes-dir)
    ROUTES_DIR="${2:?--routes-dir needs a path}"
    shift 2
    ;;
  --routes-group)
    ROUTES_GROUP="${2:?--routes-group needs a group}"
    shift 2
    ;;
  --socket-root)
    SOCKET_ROOT="${2:?--socket-root needs a path}"
    shift 2
    ;;
  --palette)
    PALETTE="${2:?--palette needs a path}"
    shift 2
    ;;
  --domain)
    DOMAIN="${2:?--domain needs a name}"
    shift 2
    ;;
  --link-scheme)
    LINK_SCHEME="${2:?--link-scheme needs a scheme}"
    shift 2
    ;;
  --link-port)
    LINK_PORT="${2:?--link-port needs a number}"
    shift 2
    ;;
  --caddy)
    CADDY="${2:?--caddy needs a path}"
    shift 2
    ;;
  --caddy-config)
    CADDY_CONFIG="${2:?--caddy-config needs a path}"
    shift 2
    ;;
  --systemctl)
    SYSTEMCTL="${2:?--systemctl needs a path}"
    shift 2
    ;;
  --anonctl)
    ANONCTL="${2:?--anonctl needs a path}"
    shift 2
    ;;
  --no-chown)
    DO_CHOWN=0
    shift
    ;;
  --max-passes)
    MAX_PASSES="${2:?--max-passes needs a number}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  reconcile | links)
    VERB="$1"
    shift
    ;;
  *) die "unknown argument '$1' (try --help)" ;;
  esac
done

[ -n "$PALETTE" ] || die "--palette is required (the declared palette is services.whereverAnon.palettePath)"
[ -n "$DOMAIN" ] || die "--domain is required (the wildcard site's domain)"
[ -r "$PALETTE" ] || die "cannot read the declared palette at '$PALETTE'"

if [ "$DO_CHOWN" = 0 ]; then
  # The isolation guarantee, structural rather than documentary: a fixture run
  # cannot touch a shared/global location even by accident.
  for pair in "$LEDGER_DIR:$PROD_LEDGER" "$STATE_DIR:$PROD_STATE" "$ROUTES_DIR:$PROD_ROUTES"; do
    if [ "${pair%%:*}" = "${pair##*:}" ]; then
      die "--no-chown is a fixture mode and refuses the production path '${pair%%:*}'"
    fi
  done
elif [ "$(id -u)" != 0 ]; then
  die "must run as root (it writes state owned by each account, and probes the live nft ruleset); pass --no-chown for a fixture run"
fi

# --- small helpers --------------------------------------------------------

# A random string of $1 characters from alphabet $2.
#
# `tr -dc <set> </dev/urandom | head -c N` is the obvious form and it is a SILENT
# KILLER under `set -euo pipefail`: tr reads urandom forever, head closes the pipe
# after N bytes, tr dies with SIGPIPE, pipefail propagates it, and set -e exits
# printing NOTHING AT ALL. That exact bug shipped in this script's interim
# predecessor and made the whole thing a no-op. Reading a BOUNDED block instead
# means tr consumes its entire input and exits 0, and bash does the slicing.
mint() {
  local want="$1" alphabet="$2" raw
  raw=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$alphabet")
  [ "${#raw}" -ge "$want" ] || die "could not mint $want characters (got ${#raw})"
  printf '%s' "${raw:0:want}"
}

# One field out of an account's state file, empty when there is no state yet.
#
# An UNREADABLE-BUT-PRESENT state file is reported once, loudly, rather than
# passing silently as "no state": the caller then treats the account as never
# minted and gives it a NEW handle and token, which changes a live URL. That is
# the right repair for a file no instance could start from anyway (the unit
# parses it with jq too, and refuses), but the operator must be able to connect
# "my URL changed" to its cause instead of hunting for one.
state_field() {
  local field="$2" file="$STATE_DIR/$1/state.json"
  [ -r "$file" ] || return 0
  jq -r --arg f "$field" '.[$f] // ""' "$file" 2>/dev/null || true
}

# Report an unparseable state file ONCE, before its fields are read.
#
# It lives here rather than inside state_field because state_field is always
# called in a command substitution, so a "warn once" flag set there dies with the
# subshell and the warning prints once per FIELD: the paragraph below would
# appear three times and read like three different problems.
warn_if_corrupt_state() {
  local account="$1" file="$STATE_DIR/$1/state.json"
  [ -r "$file" ] || return 0
  jq -e . "$file" >/dev/null 2>&1 && return 0
  warn "$account: $file is present but not parseable JSON, so its handle, token and colorway cannot be read. Treating the slot as UNPROVISIONED, which mints a new handle and token and therefore CHANGES ITS URL."
}

# THE GATE'S OWN DEPENDENCIES, checked before anything is written, for exactly the
# reason the caddy validator is resolved up front: a tool that cannot RUN must
# never look like a verdict.
#
# `anonctl probe` shells out to `getent passwd <account>` to resolve the uid, and
# it inherits this script's PATH. When getent is absent anonctl cannot tell "the
# lookup failed" from "the account does not exist", so it answers `account-missing`
# and every managed account is refused as though its passwd entry had vanished.
# That shipped: the first real run on telemaque retracted a working interface and
# told the operator to declare a slot that was already declared, while `id -u
# anon-01` answered 8802 on the same box. Fail-closed, and pointing at the wrong
# problem, which is its own kind of failure.
#
# nft is checked too: probe reads the live ruleset through it, and a missing one
# surfaces as `rules-unreadable`, i.e. also indistinguishable from a real absence.
probe_prerequisites() {
  local missing=()
  command -v getent >/dev/null 2>&1 || missing+=(getent)
  command -v "$NFT_FOR_PROBE" >/dev/null 2>&1 || missing+=(nft)
  [ "${#missing[@]}" = 0 ] || die "the forced gate cannot run: ${missing[*]} missing from PATH. \`anonctl probe\` shells out to those tools, and reports an unrunnable one as account-missing or rules-unreadable, i.e. as an ABSENCE rather than as a failure to look. Every managed account would be refused for a reason that is fail-closed but FALSE, so this stops here instead. Fix the reconcile package's runtimeInputs."
}

# The caddy binary AND the config it is actually run with, both read off the
# RUNNING unit's ExecStart.
#
# Never `caddy` from PATH: this fleet builds Caddy WITH the Cloudflare DNS plugin
# (plugins are compile-time in Caddy), so it is not in the system profile and is
# not on root's PATH, and it never will be. Resolving it from the unit means the
# validator is by construction the same binary that will later have to load the
# fragment, which is the only thing that makes validating it mean anything.
#
# The CONFIG is resolved the same way and for a sharper version of the same
# reason: a hardcoded `/etc/caddy/caddy_config` is a guess about another module's
# internals, and the day it drifts, `adapt` fails on a file that has nothing to do
# with this account, which THIS script would read as "the fragment is bad" and act
# on by deleting it. Reading both from one ExecStart makes that impossible rather
# than unlikely.
resolve_caddy() {
  local execStart=""
  if [ "$CADDY" = auto ] || [ "$CADDY_CONFIG" = auto ]; then
    execStart=$("$SYSTEMCTL" show caddy -p ExecStart --value 2>/dev/null || true)
  fi

  if [ "$CADDY" = auto ]; then
    CADDY=$(grep -oE '/nix/store/[^ ;]+/bin/caddy' <<<"$execStart" | head -1 || true)
  fi
  # A MISSING VALIDATOR IS A HARD STOP BEFORE ANYTHING IS WRITTEN, never a reason
  # to delete a fragment. The first version of the interim script called `caddy`
  # from PATH, got "command not found", read that as A FAILED VALIDATION and
  # deleted a perfectly valid fragment: a missing tool must never look like a
  # broken config.
  [ -n "$CADDY" ] && [ -x "$CADDY" ] ||
    die "cannot find the running caddy binary (looked at the caddy unit's ExecStart); is caddy converged?"

  if [ "$CADDY_CONFIG" = auto ]; then
    CADDY_CONFIG=$(grep -oE -- '--config [^ ;]+' <<<"$execStart" | head -1 | awk '{print $2}' || true)
  fi
  [ -n "$CADDY_CONFIG" ] && [ -r "$CADDY_CONFIG" ] ||
    die "cannot find the config the caddy unit runs with (looked for --config in its ExecStart); refusing to validate against a file that is not the one Caddy loads"
}

# The DECLARED slots, read from the units that actually serve them. An account in
# the ledger with no unit cannot be provisioned: the fragment would point Caddy at
# a socket nothing serves, which is a 502 rather than an interface. Reading the
# unit files keeps this script wholly generic (it names no slot, so the pool can
# grow with no change here, spec story 15).
declared_slots() {
  "$SYSTEMCTL" list-unit-files 'wherever-anon-*.socket' --no-legend 2>/dev/null |
    awk '{print $1}' | sed 's/^wherever-anon-//; s/\.socket$//' | sort
}

# The accounts anonctl MANAGES: the ledger's filenames, never its contents.
ledger_accounts() {
  [ -d "$LEDGER_DIR" ] || return 0
  find "$LEDGER_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null |
    sed 's/\.json$//' | sort
}

# A cheap digest of everything reconcile READS as a trigger, so a ledger write
# that lands mid-run is noticed and re-scanned rather than missed until the next
# trigger. systemd COALESCES a start request for a oneshot that is already
# running, so without this a `.path` firing during a run can be silently lost.
trigger_digest() {
  {
    find "$LEDGER_DIR" "$MARKER_DIR" -maxdepth 1 -type f -name '*.json' \
      -printf '%p %s %T@\n' 2>/dev/null || true
  } | sort | cksum
}

# --- the forced gate ------------------------------------------------------

PROBE_REASON=
PROBE_CODE=

# Is this account ACTUALLY jailed right now? Delegated to `anonctl probe`, which
# is anonctl's own verb for exactly this question (see the header for why this
# script no longer answers it itself). Sets PROBE_CODE to the first failing
# check's stable reason code and PROBE_REASON to a line that names the remedy.
probe_forced() {
  local account="$1" out="" rc=0 jailed detail boot
  PROBE_REASON=
  PROBE_CODE=

  out=$("$ANONCTL" probe "$account" --json 2>/dev/null) || rc=$?

  # NO DOCUMENT IS NOT A PASS. A probe that could not run at all (binary missing,
  # too old to have the verb, killed) must read as "undetermined", which this gate
  # treats exactly as "not jailed".
  if [ -z "$out" ] || ! jq -e '.jailed != null' <<<"$out" >/dev/null 2>&1; then
    PROBE_CODE=probe-unusable
    PROBE_REASON="probe-unusable: \`$ANONCTL probe $account --json\` produced no usable verdict (exit $rc). This gate has NO fallback on purpose: a weaker second opinion would fail open exactly when the strong one is unavailable. Check that anonctl is 0.7.0 or newer (\`anonctl --version\`) and that this ran as root."
    return 1
  fi

  jailed=$(jq -r '.jailed' <<<"$out")
  if [ "$jailed" = true ]; then
    # INFORMATIONAL ONLY, never a gate. A marker survives a reboot while the proof
    # does not, so anonctl records which boot it was made in; but the rules-loaded
    # check above is live, so a previous-boot proof plus live forcing is the normal
    # state after every reboot. Refusing on it would retract every interface on
    # every boot. Absent means unknown, never a mismatch.
    boot=$(jq -r '.boot.state // ""' <<<"$out")
    case "$boot" in
    previous-boot | previous_boot)
      note "$account: jailed, and its anonctl proof was made in an EARLIER boot (the kernel rules are live, so this is normal after a reboot; \`anonctl verify $account\` re-proves it end to end)"
      ;;
    esac
    return 0
  fi

  PROBE_CODE=$(jq -r 'first(.checks[] | select(.ok | not) | .reason) // "unknown"' <<<"$out")
  detail=$(jq -r 'first(.checks[] | select(.ok | not) | .detail) // ""' <<<"$out")

  # Map anonctl's stable reason code to what the OPERATOR has to do about it. The
  # code is the contract; the remedy is this fleet's knowledge of its own box.
  local remedy
  case "$PROBE_CODE" in
  no-marker)
    remedy="anonctl manages the account but has never PROVEN it anonymized. Bring its endpoint up and run: anonctl verify $account"
    ;;
  marker-unreadable)
    remedy="the marker could not be read, which is UNDETERMINED rather than absent. Usually this ran without root; check the mode of /etc/anonctl (anonctl 0.7.0+ repairs it to 0755 on any root invocation)."
    ;;
  account-missing)
    remedy="the account has no passwd entry, so the installed rules govern a uid that belongs to nobody. Declare the slot in my.anonAccounts and converge, or remove the account."
    ;;
  uid-drift)
    remedy="the rules were installed for a DIFFERENT uid than the account has today, so the forcing governs a uid this account no longer is. Re-install it: anonctl rm $account && anonctl add $account"
    ;;
  rules-unreadable)
    remedy="the live ruleset could not be read, which is UNDETERMINED rather than absent: probe needs root and never self-elevates. Check that this unit runs as root and that nft is on its PATH."
    ;;
  table-missing)
    remedy="the account's nft table is not loaded at all, so nothing forces its egress. Check: systemctl status anonctl-nftables.service"
    ;;
  uid-not-governed)
    remedy="the account's nft table IS loaded but does NOT funnel this uid into the fail-closed chain, so the rules exist and do not apply. This is the case a bare 'skuid' grep cannot see. Re-install the forcing: anonctl rm $account && anonctl add $account"
    ;;
  *)
    remedy="anonctl reports it is not jailed. Run \`anonctl probe $account\` as root for the full per-check report."
    ;;
  esac
  PROBE_REASON="$PROBE_CODE: $detail"$'\n'"    remedy: $remedy"
  return 1
}

# --- caddy fragments ------------------------------------------------------

fragment_text() {
  local handle="$1" socket="$2"
  cat <<EOF
# An anon interface, keyed only by its handle. Names no account on purpose.
@$handle host $handle.$DOMAIN
handle @$handle {
	reverse_proxy unix/$socket
}
EOF
}

# Adapt the WHOLE config, which is what a restart or a reboot will do. Exits
# non-zero with caddy's own message on stderr when the config no longer adapts.
caddy_adapts() {
  local log="$STATE_DIR/.caddy-adapt.log"
  if "$CADDY" adapt --adapter caddyfile --config "$CADDY_CONFIG" >/dev/null 2>"$log"; then
    rm -f "$log"
    return 0
  fi
  tail -20 "$log" >&2 || true
  rm -f "$log"
  return 1
}

# Write a fragment and keep it ONLY if the config still adapts with it in place.
write_fragment() {
  local account="$1" handle="$2" socket="$3" target tmp previous=""
  target="$ROUTES_DIR/$handle.caddy"
  if [ -r "$target" ] && [ "$(cat "$target")" = "$(fragment_text "$handle" "$socket")" ]; then
    # IDEMPOTENT on content, so not even an mtime is disturbed. Mode and owner are
    # still re-asserted, for the same reason the state file's ownership is (see
    # provision): root's `adapt` reads a fragment Caddy may not be able to, so a
    # 0640 root:root fragment left by an older tool validates perfectly here and
    # then stops Caddy loading at its next START, which is precisely the long-fuse
    # failure this whole validation exists to prevent.
    chmod 640 "$target"
    [ "$DO_CHOWN" = 0 ] || chown "root:$ROUTES_GROUP" "$target"
    return 0
  fi
  [ ! -r "$target" ] || previous=$(cat "$target")
  tmp=$(mktemp "$ROUTES_DIR/.$handle.XXXXXX")
  fragment_text "$handle" "$socket" >"$tmp"
  # 0640 root:<proxy group>, NOT 0644. A fragment necessarily carries the slot's
  # socket path next to the handle, so a world-readable one publishes the
  # handle-to-slot mapping to every local user for free. The name is local-visible
  # by design (/etc/passwd), but the MAPPING is what an interface's privacy rests
  # on, and Caddy is the only reader that needs it.
  chmod 640 "$tmp"
  [ "$DO_CHOWN" = 0 ] || chown "root:$ROUTES_GROUP" "$tmp"
  mv "$tmp" "$target"
  if ! caddy_adapts; then
    # ROLL BACK TO WHAT WAS THERE, rather than unconditionally deleting. The adapt
    # covers the WHOLE config, so it can fail for a reason that has nothing to do
    # with this account (a hand-placed broken fragment, a broken caddy_config), and
    # deleting then would take a WORKING interface off the air as collateral for
    # someone else's mistake. Restoring is still safe: the previous content is by
    # construction content that adapted when it was written.
    if [ -n "$previous" ]; then
      printf '%s\n' "$previous" >"$target"
      chmod 640 "$target"
      [ "$DO_CHOWN" = 0 ] || chown "root:$ROUTES_GROUP" "$target"
      die "the routing fragment for $account did not adapt; RESTORED the previous one rather than leaving a reboot trap on disk (a bad fragment does not disturb the running Caddy, it stops the NEXT start, taking every vhost on this machine with it). If the failure above names another file, fix that: this account's own fragment may be fine."
    fi
    rm -f "$target"
    die "the routing fragment for $account did not adapt; REMOVED it rather than leaving a reboot trap on disk (a bad fragment does not disturb the running Caddy, it stops the NEXT start, taking every vhost on this machine with it)"
  fi
  CHANGED=1
}

drop_fragment() {
  local handle="$1"
  [ -n "$handle" ] || return 0
  if [ -e "$ROUTES_DIR/$handle.caddy" ]; then
    rm -f "$ROUTES_DIR/$handle.caddy"
    CHANGED=1
  fi
}

# --- per-account actions --------------------------------------------------

# Pick a colorway: prefer one no other account has CLAIMED, so that while the
# palette is larger than the account count every instance looks different. When
# every entry is claimed, fall back to a deterministic choice keyed on the HANDLE
# (never the username, which the handle exists to hide) rather than failing: a
# repeated colour is cosmetic, whereas refusing to reconcile would cost the
# operator a working interface over decoration.
pick_colorway() {
  local account="$1" handle="$2" claimed c n idx
  claimed=$(for d in "$STATE_DIR"/*/state.json; do
    [ -r "$d" ] || continue
    case "$d" in "$STATE_DIR/$account/state.json") continue ;; esac
    jq -r '.colorway // empty' "$d" 2>/dev/null || true
  done | sort -u)

  while read -r c; do
    [ -n "$c" ] || continue
    if ! printf '%s\n' "$claimed" | grep -Fqx "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done < <(jq -r 'keys_unsorted[]' "$PALETTE")

  n=$(jq -r 'keys_unsorted | length' "$PALETTE")
  [ "$n" -gt 0 ] || die "the declared palette at $PALETTE is empty"
  idx=$(($(printf '%s' "$handle" | cksum | cut -d' ' -f1) % n))
  jq -r --argjson i "$idx" 'keys_unsorted[$i]' "$PALETTE"
}

provision() {
  local account="$1" dir state handle token colorway socket tmp desired
  dir="$STATE_DIR/$account"
  state="$dir/state.json"
  socket="$SOCKET_ROOT/$account/wherever.sock"

  mkdir -p "$dir"
  chmod 700 "$dir"
  warn_if_corrupt_state "$account"

  # STICKY: an account that already has a handle, a token or a colorway keeps
  # every one of them. Nothing here recomputes a minted value.
  handle=$(state_field "$account" handle)
  token=$(state_field "$account" token)
  colorway=$(state_field "$account" colorway)

  # OPAQUE AND RANDOM, never derived from the username: a derived handle leaks
  # the very name it exists to hide.
  [ -n "$handle" ] || handle=$(mint 8 'abcdefghijkmnpqrstuvwxyz23456789')
  [ -n "$token" ] || token=$(mint 32 'A-Za-z0-9')
  [ -n "$colorway" ] || colorway=$(pick_colorway "$account" "$handle")

  if ! jq -e --arg c "$colorway" 'has($c)' "$PALETTE" >/dev/null; then
    warn "$account: colorway '$colorway' is not in the declared palette, so its instance will use the default look (the palette was re-tuned; the assignment is deliberately never recomputed, because that would repaint an instance the operator has learned to recognise)"
  fi

  # The four-field contract with modules/wherever-anon.nix. `socketPath` is a
  # CROSS-CHECK rather than an instruction: the unit's ListenStream is evaluated
  # at build time, and it REFUSES to start when the two disagree, so Caddy can
  # never be pointed at a socket nothing serves.
  desired=$(jq -n --arg s "$socket" --arg t "$token" --arg h "$handle" --arg c "$colorway" \
    '{socketPath:$s, token:$t, handle:$h, colorway:$c}')

  if [ ! -r "$state" ] || [ "$(cat "$state")" != "$desired" ]; then
    tmp=$(mktemp "$dir/.state.XXXXXX")
    printf '%s\n' "$desired" >"$tmp"
    # 0600 and account-owned: the unit reads it AS the account, and the token
    # must not be world-readable. Trailing newline included so the file is a
    # well-behaved text file; the comparison above uses $(cat), which strips it,
    # so this stays byte-stable across runs.
    chmod 600 "$tmp"
    mv "$tmp" "$state"
    note "$account: state written (colorway $colorway)"
  fi

  # OWNERSHIP IS RE-ASSERTED EVERY RUN, outside the write branch above. A state
  # file whose CONTENT is already correct can still have the wrong owner (written
  # by an earlier tool, or restored from a backup), and the unit reads it AS the
  # account, so a root-owned file is an instance that refuses to start for a
  # reason its journal cannot explain. chown touches ctime, never mtime, so this
  # costs the idempotency property nothing.
  if [ "$DO_CHOWN" = 1 ] && [ -e "$state" ]; then
    chown "$account:$account" "$state" "$dir"
  fi

  write_fragment "$account" "$handle" "$socket"

  # A slot whose service refused to start (every slot has no state until this
  # runs) leaves BOTH units `failed`, and writing the state file does NOT revive
  # it: a failed socket cannot activate. Unconditional because it is idempotent
  # and a conditional check would be a race.
  "$SYSTEMCTL" reset-failed "wherever-anon-$account.socket" "wherever-anon-$account.service" 2>/dev/null || true
  if ! "$SYSTEMCTL" start "wherever-anon-$account.socket"; then
    # NOT a warning-and-carry-on: the fragment above is now live, so this is a
    # handle the operator has just been handed that answers 502. Every other
    # "this slot is not serving" condition exits 3 and lands in `systemctl
    # --failed`, and this one has to as well or it is the quietest failure here.
    REFUSED=1
    warn "$account: its socket unit would not start, so the handle now routed to it will answer 502. Check: systemctl status wherever-anon-$account.socket"
  fi
}

# Retract the interface but KEEP the state, so a slot whose forcing lapses and
# comes back returns at the same handle and the same token.
suspend() {
  local account="$1" handle
  handle=$(state_field "$account" handle)
  drop_fragment "$handle"
  "$SYSTEMCTL" stop "wherever-anon-$account.service" "wherever-anon-$account.socket" 2>/dev/null || true
}

# The `anonctl rm` signal: the identity is gone, so everything goes.
teardown() {
  local account="$1" handle
  handle=$(state_field "$account" handle)
  drop_fragment "$handle"
  "$SYSTEMCTL" stop "wherever-anon-$account.service" "wherever-anon-$account.socket" 2>/dev/null || true
  "$SYSTEMCTL" reset-failed "wherever-anon-$account.socket" "wherever-anon-$account.service" 2>/dev/null || true
  rm -rf "${STATE_DIR:?}/$account"
  note "$account: left the ledger, so its state and routing are removed"
}

# --- one reconcile pass ---------------------------------------------------

reconcile_pass() {
  local managed slots account handle keep frag dir

  mkdir -p "$STATE_DIR" "$ROUTES_DIR"
  managed=$(ledger_accounts)
  slots=$(declared_slots)
  keep=""

  # Unit discovery returning NOTHING while accounts exist is a different
  # condition from a slot that is genuinely undeclared, and the per-account
  # message below would misdiagnose it as the latter for every account at once.
  if [ -z "$slots" ] && [ -n "$managed" ]; then
    warn "no wherever-anon-*.socket units exist at all (asked: $SYSTEMCTL list-unit-files). Either this host declares no slots, or unit discovery failed; every managed account is about to be refused for that reason and none of them is necessarily undeclared."
  fi

  # A MISSING LEDGER DIRECTORY IS NOT AN EMPTY LEDGER, and conflating the two
  # would be the most destructive bug in this script. Teardown below treats
  # "absent from the ledger" as `anonctl rm`, which DELETES the account's state,
  # i.e. its handle and its token, irreversibly. `/etc/anonctl` is imperative
  # state belonging to a third-party tool that this fleet has already measured as
  # unable to install itself on NixOS, so the directory genuinely can be missing:
  # anonctl not installed yet, a rebirth that wiped /etc, a layout change. Every
  # one of those would read as "the operator removed every account".
  #
  # This is the same distinction the validator makes one function away, where a
  # missing tool must never look like a broken config.
  if [ ! -d "$LEDGER_DIR" ]; then
    # PROVISIONED state is a state.json reconcile wrote, not a directory: the
    # wherever-anon module's tmpfiles rules create an empty <account>/ for
    # every DECLARED slot at boot, so on a machine anonctl has never run on
    # (every fresh install) a directory test refused every boot. (wasisabi fix;
    # the my-boxes original has the same latent failure on a rebirth.)
    if [ -n "$(find "$STATE_DIR" -mindepth 2 -maxdepth 2 -name state.json -print -quit 2>/dev/null)" ]; then
      REFUSED=1
      warn "anonctl's ledger directory $LEDGER_DIR DOES NOT EXIST, while provisioned state does. Nothing can be concluded about which accounts were removed, so teardown and the orphan sweep are SKIPPED rather than deleting handles and tokens that cannot be recovered. Install/repair anonctl, or remove the state deliberately."
    fi
    return 0
  fi

  while read -r account; do
    [ -n "$account" ] || continue
    if ! printf '%s\n' "$slots" | grep -Fqx "$account"; then
      REFUSED=1
      warn "REFUSING $account: anonctl manages it, but this host declares no wherever-anon-$account unit to serve it, so a routing fragment would point Caddy at a socket nothing serves. Declare the slot in my.anonAccounts (and converge) or remove the account."
      continue
    fi
    if probe_forced "$account"; then
      provision "$account"
      keep="$keep$(state_field "$account" handle)"$'\n'
    else
      REFUSED=1
      suspend "$account"
      warn "REFUSING $account: anonctl MANAGES this account but it is NOT PROVEN FORCED, so no interface is provisioned and any existing routing has been retracted. An interface for an unforced account looks anonymised while its sessions egress in the clear, which is the exact failure this feature exists to prevent."
      warn "  reason: $PROBE_REASON"
      # WHICH recovery is automatic depends on WHY it was refused, and saying
      # "this heals itself" for a reason that heals nothing is worse than saying
      # nothing: the operator repairs the jail, believes the interface is coming
      # back, and it never does. Fixing a marker (or re-running verify) touches
      # the watched marker directory; fixing the RULESET touches nothing under
      # /etc/anonctl, so only the periodic re-check picks that up.
      case "$PROBE_CODE" in
      no-marker | marker-unreadable | uid-drift)
        warn "  reconcile re-runs on its own when that changes: the marker directory is watched."
        ;;
      *)
        warn "  nothing under /etc/anonctl changes when that is fixed, so the routing returns at the next periodic reconcile, or immediately with: systemctl start wherever-anon-reconcile.service"
        ;;
      esac
    fi
  done <<<"$managed"

  # TEARDOWN: state for an account that is no longer in the ledger.
  for dir in "$STATE_DIR"/*; do
    [ -d "$dir" ] || continue
    account=$(basename "$dir")
    if ! printf '%s\n' "$managed" | grep -Fqx "$account"; then
      teardown "$account"
    fi
  done

  # ORPHAN SWEEP: a fragment no provisioned account claims (a state file removed
  # by hand, a handle re-minted by an older tool). Reconcile is authoritative
  # over the routes directory, so a stale fragment cannot keep routing to a slot.
  for frag in "$ROUTES_DIR"/*.caddy; do
    [ -e "$frag" ] || continue
    handle=$(basename "$frag" .caddy)
    if printf '%s' "$keep" | grep -Fqx "$handle"; then
      continue
    fi
    rm -f "$frag"
    CHANGED=1
    warn "removed the orphan routing fragment $handle.caddy (no provisioned account claims that handle)"
  done
}

do_reconcile() {
  local before after pass=1

  probe_prerequisites
  resolve_caddy

  # Serialize against another reconcile: two triggers close together, or an
  # operator running this by hand while the path unit fires.
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/.reconcile.lock"
  # BOUNDED at 60s, which is deliberately SHORTER than the unit's own start
  # timeout: wait longer than that and systemd kills the run first, so the
  # operator gets "Start operation timed out" instead of the precise message
  # below, and the diagnostic this line exists for is never seen. A real pass is
  # a handful of file writes and one `caddy adapt`, so a minute already means
  # something is stuck.
  flock -w 60 9 ||
    die "another reconcile has held the lock at $STATE_DIR/.reconcile.lock for a minute; refusing to run concurrently with it"

  while :; do
    before=$(trigger_digest)
    reconcile_pass
    # THE RELOAD IS INSIDE THE LOOP, and only when something actually changed, so
    # an unchanged ledger really is a no-op. Inside, because the digest below has
    # to cover the reload WINDOW too: the `.path` unit's watch is disarmed while
    # this service runs, so an `anonctl add` landing during a reload would
    # otherwise be seen by nobody and produce the "I ran add and nothing
    # happened" symptom this loop exists to prevent.
    if [ "$CHANGED" = 1 ]; then
      CHANGED=0
      if "$SYSTEMCTL" is-active --quiet caddy 2>/dev/null; then
        "$SYSTEMCTL" reload caddy || warn "caddy did not reload; the fragments on disk are valid and will be picked up at its next start"
      else
        note "caddy is not running, so nothing to reload; it reads the fragments when it starts"
      fi
    fi
    after=$(trigger_digest)
    [ "$before" != "$after" ] || break
    pass=$((pass + 1))
    if [ "$pass" -gt "$MAX_PASSES" ]; then
      warn "the ledger kept changing across $MAX_PASSES passes; stopping (the next trigger, or the periodic re-check, will reconcile the rest)"
      break
    fi
    note "the ledger changed during the run, re-scanning (pass $pass)"
  done

  if [ "$REFUSED" = 1 ]; then
    warn "at least one managed account was REFUSED (see above). Exiting non-zero so this shows up in \`systemctl --failed\` rather than scrolling past."
    exit 3
  fi
}

do_links() {
  local account state handle
  echo "# These links are CREDENTIALS: each carries its instance's token in the URL fragment."
  printf '%-14s %-10s %s\n' ACCOUNT COLORWAY LINK
  for state in "$STATE_DIR"/*/state.json; do
    [ -r "$state" ] || continue
    account=$(basename "$(dirname "$state")")
    handle=$(jq -r '.handle // ""' "$state")
    # The token travels in the HASH, never the query. A fragment is never sent to
    # the server, so it cannot reach an access log, a Referer header or a proxy
    # log; wherever 0.17.0 adopts it from there, persists it and strips it from
    # the address bar.
    printf '%-14s %-10s %s://%s.%s%s/#token=%s\n' \
      "$account" "$(jq -r '.colorway // "-"' "$state")" "$LINK_SCHEME" "$handle" "$DOMAIN" \
      "${LINK_PORT:+:$LINK_PORT}" "$(jq -r '.token // ""' "$state")"
  done
}

case "$VERB" in
reconcile) do_reconcile ;;
links) do_links ;;
esac
