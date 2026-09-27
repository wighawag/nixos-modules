# shellcheck shell=bash
# scripts/caddy-routes-guard.sh
#
# MAKE THE CONFIG ADAPT BEFORE CADDY IS ALLOWED TO TRY, by quarantining the
# fragment that breaks it. Runs as an ExecStartPre on caddy.service.
#
# WHY THIS EXISTS, measured on telemaque 2026-09-25 rather than reasoned about.
# The anon dispatcher's wildcard site glob-imports a directory of mutable
# fragments (ADR-0012). A fragment that does not parse is harmless while Caddy is
# UP -- a running Caddy has already adapted its config, so a bad fragment does not
# disturb it and a reload carrying one fails while the previous config keeps
# serving, which was demonstrated live -- and it is fatal at the next START:
#
#   Error: adapting config using caddyfile: /etc/caddy/anon-routes/zzz-broken.caddy:1:
#          unrecognized directive: this
#   caddy.service: Failed with result 'exit-code'.
#
# THE PART THAT MADE THIS A TASK RATHER THAN A NOTE: nothing retried, and nothing
# rescued it. `Restart=on-failure` did NOT fire, because the process exited during
# startup before the Type=notify READY, so the start job failed and systemd left
# the unit `failed` (measured: NRestarts=0, not one "Scheduled restart" line).
# And scripts/anon-reconcile.sh, whose orphan sweep would have removed the
# fragment, only reloads Caddy when it is ALREADY ACTIVE and deliberately never
# starts it. So one bad fragment at boot means every vhost on the machine is
# down, indefinitely, including the operator's own remote-control bridge.
#
# THE ERROR NAMES THE FILE, which is what lets this be precise instead of blunt:
# adapt, and while it fails with an error naming a file inside the routes
# directory, move that file aside and try again. A config that fails WITHOUT
# naming a fragment is a fault in the host's own declared config, so nothing is
# touched and Caddy is left to fail: hiding a repo bug is worse than a loud one.
#
# IT NEVER BLOCKS THE START. Every outcome short of a usage error exits 0, and
# the unit prefixes it with `-` as well, so a bug in this script cannot become the
# reason the machine has no web server. The wiring also needs `+` (run as root):
# ExecStartPre inherits User=caddy, the fragments are 0640 root:caddy in a
# 0755 root root directory, so an unprivileged guard could READ the problem and
# not FIX it.
#
# SELF-HEALING FOLLOWS FOR FREE. A quarantined fragment that belongs to a
# provisioned account is rewritten by the next reconcile run (it derives
# fragments from each account's state file, proven live by deleting the whole
# routing directory and watching both come back with the same handles). One that
# belongs to nothing stays in quarantine, where a human can look at it.
#
# EVERY PATH IS AN ARGUMENT, like anon-reconcile and for the same reason: it
# makes the whole thing runnable against a scratch directory and a real caddy
# with no root and no live box (tests/caddy-routes-guard-fixture.sh), which is
# where its behaviour is actually proven.

set -euo pipefail

ROUTES_DIR=""
QUARANTINE_DIR=""
CADDY=""
CONFIG=""
# A bound on the loop, so a pathological case (a fragment that cannot be moved, an
# error message that keeps naming the same file) cannot spin. It is far above any
# real fragment count: this fleet declares two anon slots.
MAX_QUARANTINES=64

note() { echo "caddy-routes-guard: $*"; }
warn() { echo "caddy-routes-guard: $*" >&2; }
die() {
  echo "caddy-routes-guard: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: caddy-routes-guard --routes-dir DIR --quarantine-dir DIR --caddy PATH --config PATH

Adapt Caddy's config; while adaptation fails naming a fragment inside DIR, move
that fragment into the quarantine directory and retry. Exits 0 whether or not it
quarantined anything, so it can never be the reason Caddy does not start.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --routes-dir)
      ROUTES_DIR="${2:?--routes-dir needs a value}"
      shift 2
      ;;
    --quarantine-dir)
      QUARANTINE_DIR="${2:?--quarantine-dir needs a value}"
      shift 2
      ;;
    --caddy)
      CADDY="${2:?--caddy needs a value}"
      shift 2
      ;;
    --config)
      CONFIG="${2:?--config needs a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

[ -n "$ROUTES_DIR" ] || die "--routes-dir is required"
[ -n "$QUARANTINE_DIR" ] || die "--quarantine-dir is required"
[ -n "$CADDY" ] || die "--caddy is required"
[ -n "$CONFIG" ] || die "--config is required"

# Absolute, all four. A relative path here would resolve against whatever
# directory systemd happened to start the unit in, and the one thing this script
# must never do is move a file it was not pointed at.
for p in "$ROUTES_DIR" "$QUARANTINE_DIR" "$CADDY" "$CONFIG"; do
  case "$p" in
    /*) ;;
    *) die "every path must be absolute, got '$p'" ;;
  esac
done

# THE QUARANTINE MUST NOT BE INSIDE THE GLOB, or a quarantined fragment is
# re-imported at the next start and the guard quarantines it again forever.
case "$QUARANTINE_DIR/" in
  "$ROUTES_DIR"/*) die "--quarantine-dir is inside --routes-dir, so a quarantined fragment would be re-imported" ;;
esac

[ -x "$CADDY" ] || die "--caddy '$CADDY' is not executable"

if [ ! -e "$CONFIG" ]; then
  note "no config at $CONFIG yet; nothing to validate"
  exit 0
fi

# The routes dir is allowed to be absent: a glob matching nothing and a missing
# directory are both valid to Caddy (measured, and the zero-account case is the
# default case on every freshly born box).
if [ ! -d "$ROUTES_DIR" ]; then
  note "no routes directory at $ROUTES_DIR; nothing to guard"
  exit 0
fi

# The routes dir, escaped for use INSIDE a regex. Without this a `.` or `+` in a
# configured path would quietly match more than the literal directory.
# shellcheck disable=SC2016  # the `$` in that character class is a literal to be
# escaped, not an expansion: single quotes are the point.
routes_re=$(printf '%s' "$ROUTES_DIR" | sed 's/[][\.*^$(){}?+|]/\\&/g')

quarantined=0

while :; do
  # stdout is the adapted JSON and is discarded; the diagnostic is on stderr.
  if err=$("$CADDY" adapt --config "$CONFIG" --adapter caddyfile 2>&1 >/dev/null); then
    if [ "$quarantined" -gt 0 ]; then
      note "config adapts again after quarantining $quarantined fragment(s)"
    fi
    exit 0
  fi

  bad=$(printf '%s\n' "$err" | grep -oE "${routes_re}/[^ :\"']+\.caddy" | head -1 || true)

  if [ -z "$bad" ]; then
    warn "the config does NOT adapt and the error names no fragment under $ROUTES_DIR."
    warn "Leaving every file alone: this is a fault in the host's own config, and"
    warn "quarantining a fragment would hide it rather than fix it. Caddy will fail."
    printf '%s\n' "$err" >&2
    exit 0
  fi

  # Defensive: only ever move a file that sits DIRECTLY in the routes directory.
  # The regex is anchored on that prefix, but an error message is untrusted input
  # and `..` in it must not become a path traversal performed as root.
  case "$bad" in
    */../*) die "refusing to act on '$bad': it escapes $ROUTES_DIR" ;;
  esac
  if [ "$(dirname "$bad")" != "$ROUTES_DIR" ]; then
    warn "refusing to act on '$bad': not directly inside $ROUTES_DIR"
    exit 0
  fi
  if [ ! -e "$bad" ]; then
    warn "the error names '$bad' but no such file exists; stopping"
    printf '%s\n' "$err" >&2
    exit 0
  fi

  mkdir -p "$QUARANTINE_DIR"
  chmod 0700 "$QUARANTINE_DIR"
  dest="$QUARANTINE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$bad")"
  if ! mv -f "$bad" "$dest"; then
    warn "could not move '$bad' out of the way; stopping so Caddy's own failure is the visible one"
    exit 0
  fi

  # 0600 ON THE FILE, not just 0700 on the directory. A fragment names a handle
  # and a socket path, and `mv` preserves whatever mode the writer used: the one
  # that triggered this guard's first live run arrived from `tee` as 0644, so the
  # directory was the only thing protecting it. Two independent modes is the
  # difference between a mistake and a disclosure.
  chmod 0600 "$dest"

  quarantined=$((quarantined + 1))
  warn "QUARANTINED $bad -> $dest"
  warn "  because the config would not adapt: $(printf '%s' "$err" | head -1)"

  if [ "$quarantined" -ge "$MAX_QUARANTINES" ]; then
    warn "giving up after $MAX_QUARANTINES quarantines; something is wrong beyond one bad fragment"
    exit 0
  fi
done
