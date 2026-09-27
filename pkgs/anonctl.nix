# packages/anonctl.nix
#
# The per-UID forced-egress manager and its data-path shim, as STORE-PATH
# executables.
#
# Packaged here for the reason this repo packages offshoot-fanout and Pi the same
# way: an imperative global install is undeclared state that no rebuild reproduces
# and no rollback undoes. anonctl is the strongest case in the tree for that rule,
# because it is the thing that decides whether an account is jailed, and it has
# already drifted here: telemaque ran `/usr/local/bin/anonctl` at v0.3.1 (installed
# by hand from the upstream install.sh) for weeks while this repo's own host
# comments assumed v0.5.0 behaviour that binary did not have.
#
# `packages/` (vs `services/`) is the usual distinction: this is an operator CLI a
# host puts on PATH, belonging to no service.
#
# TWO BINARIES, AND BOTH ARE REQUIRED. `anonctl` is the manager (not in the data
# path: it installs nftables rules and systemd units as root, the ufw stance).
# `anonctl-shim` IS the data path: one instance per anon account under its own uid,
# a transparent TCP-to-SOCKS relay plus a DNS-over-SOCKS-TCP forwarder. The
# generated `anonctl-shim@<account>.service` names it, so an account cannot run
# without it. buildGoModule builds both main packages, so both land in $out/bin.
#
# WHAT THIS DOES *NOT* DECLARE, deliberately: the per-account forcing. The nftables
# tables, the per-account enablement symlinks and the ledger under /etc/anonctl are
# anonctl's own runtime state, created by `anonctl add`/`update` as root. The two
# SHARED unit files are no longer in that list: since 0.9.0 upstream exports their
# text and honours a host-owned marker, so modules/anonctl-units.nix declares them
# and this package is where their source text comes from (see the postInstall
# below). The ownership split that argued for is now upstream's ADR-0012, and the
# per-account half stays an operator verb after a bump:
#
#   sudo anonctl update <account> --endpoint socks5h://127.0.0.1:9050
#
# THE UNIT TEXT IS SHIPPED AS DATA, which is what makes declaring those units
# possible without a hand-maintained copy. Upstream generates
# share/anonctl/units/*.service.in from the SAME function `anonctl add` installs
# through (three upstream tests hold the two byte-identical), so the file this
# fleet substitutes cannot drift from the definition anonctl believes it installed.
# buildGoModule installs binaries only, so the postInstall below copies that
# directory in; without it `${anonctl}/share/anonctl/units` does not exist and the
# module that consumes it fails at BUILD time rather than at boot.
#
# STORE PATHS AND THE UNITS, the one interaction worth knowing, and 0.9.0 flips it
# for this fleet. anonctl RESOLVES the binaries its units name and bakes the path
# verbatim, specifically so it never bakes a `/nix/store` path that a later GC
# deletes and leaves ExecStart pointing at nothing (see anonctl's own
# work/notes/observations/resolved-unit-binaries-can-bake-a-nix-store-path-from-path.md,
# which lives in THAT repo rather than this one, and its `preferStableAlias`). That rule is about a path anonctl resolves at
# install time, which nothing tracks. A path this repo DECLARES is the opposite
# case: the unit text is itself a store file, Nix scans it for references, so
# `${pkgs.nftables}/bin/nft` inside it is a real edge from the system closure and
# cannot be collected while the generation naming it exists. Upstream pinned that
# distinction by test (`verify`'s volatile-path check names /tmp, /var/tmp,
# /dev/shm and /run/user, and deliberately NOT /nix/store). So in host-owned mode
# the ExecStart paths are store paths, and that is the stronger form.
#
# CGO_ENABLED=0 MIRRORS THE RELEASE and is load-bearing for the shim: upstream's
# goreleaser config builds both binaries static, and says so of the shim in
# particular. Keeping it identical here means the store build is the same artifact
# the project tests and ships, rather than a variant this fleet invented.
#
# Bumping is two steps:
#   1. set `version` to the new tag,
#   2. set `hash` to lib.fakeHash, build, and paste the hash nix reports.
# `vendorHash` only changes when go.mod/go.sum do, and the anoncore dependency has
# moved on each of the last two bumps (v0.2.0 -> v0.3.0 for 0.7.0, v0.3.0 -> v0.4.0
# for 0.8.0), so expect BOTH hashes to change until that settles.
# TAKE A TEST-ONLY RELEASE ANYWAY, which this fleet briefly argued against and was
# wrong about. v0.8.1 changes two `_test.go` files and nothing else (`git diff
# --name-only v0.8.0..v0.8.1` lists no non-test Go file, and its vendorHash is
# byte-identical to 0.8.0's, which independently proves go.mod/go.sum did not
# move), so it is tempting to call the binary unchanged and skip the churn.
#
# It is NOT unchanged, for two reasons worth remembering the next time this
# argument comes up. `ldflags` below bakes `-X main.version`, so the binary
# self-reports its own version; and anonctl PERSISTS that string, as
# `anonctlVersion` in every marker it writes, which sibling tools read. Staying a
# release behind would therefore stamp a wrong provenance into on-disk state that
# outlives the decision, to save one cheap rebuild of a small Go program.
#
# The general rule this encodes: a pin is a claim about WHAT IS RUNNING, so it
# should track the release even when the diff looks inert. "Only tests changed"
# is a judgement the next reader has to re-derive to trust, and it goes stale the
# moment another release lands.
#
# 0.9.0 IS A HARD FLOOR HERE, not a preference: it is the release that ships
# `units print`, the `.in` data files and the `/etc/anonctl/units.host-owned`
# marker. Under 0.8.1 the marker means nothing, so `add` and `update` would write
# their own copy of each unit next to this fleet's declaration -- two definitions
# of one unit, with /etc/systemd/system silently outranking
# /usr/local/lib/systemd/system. The module asserts the floor rather than trusting
# this comment.
#
# 0.11.0 IS A BUMP THAT NEEDS THE OPERATOR VERB, every account, before `use`
# works again. It takes 0.10.0 along with it (the DNS forwarder holds one stream
# per account and caches, and a failed lookup answers SERVFAIL with a reason
# instead of going silent, upstream ADR-0013) and adds closure (c), upstream
# ADR-0014: only the account's uid may talk to its shim's ports, which were open
# to every local uid, this fleet's operator and services included. Closure (c)
# lives in each account's nft table, which the binary does not rewrite, so until
# `sudo anonctl update <account> --endpoint ...` re-applies it, that account's
# `verify` fails `shim-ports-closure` (it prints the exact command) and `use` /
# `exec` refuse it. Deliberately: green would claim a closure it does not have.
# Also from 0.11.0: timing an account's DNS has to run AS the account (inside
# `anonctl use`), since querying its shim port from your own uid is now refused.
{
  pkgs,
  # Explicit, never a branch: the binary that decides whether an account is jailed
  # must not change because an upstream push happened on a Tuesday.
  version ? "0.11.0",
}:
pkgs.buildGoModule {
  pname = "anonctl";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "wighawag";
    repo = "anonctl";
    tag = "v${version}";
    hash = "sha256-Vya9PCJWOPc29MtUtHELLVStVWnbXv8jk3LniFX7rsY=";
  };

  # Depends only on go.mod/go.sum, and 0.8.0 moved them again: anoncore v0.4.0
  # carries `status --json`'s degradation to an explicit `forcing.state` of
  # unknown (it used to exit 1 with no document when the marker was unreadable,
  # which this fleet reported), alongside 0.7.0's marker directory-mode repair and
  # the list/probe contract. Unchanged through 0.11.0: `git diff v0.9.0..v0.11.0 --
  # go.mod go.sum` is empty upstream.
  vendorHash = "sha256-x5+9bttNc04hnye1HDpaylBA83IjFcKGyJPzFzKqE+c=";

  env.CGO_ENABLED = 0;

  # THE UNIT TEMPLATES, AS DATA. Upstream's release archive carries
  # share/anonctl/units/*.service.in; buildGoModule installs $out/bin and nothing
  # else, so they are copied here from the same src the binaries were built from.
  # That coupling is the point: the text and the binary that validates it move
  # together on every bump, and a bump that dropped the directory upstream would
  # fail this build rather than ship a module substituting a file that is gone.
  postInstall = ''
    install -Dm444 -t $out/share/anonctl/units share/anonctl/units/*.service.in
  '';

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  # Upstream's own gate is `go test ./...`; the slow, privileged suites sit behind
  # the `integration` tag and need root, nft and setpriv, which a Nix builder has
  # none of, so they are correctly out of scope here.
  meta = {
    description = "Force one Unix account's egress through an anonymizer at the kernel level, fail-closed, and prove it";
    homepage = "https://github.com/wighawag/anonctl";
    license = pkgs.lib.licenses.agpl3Only;
    mainProgram = "anonctl";
    platforms = pkgs.lib.platforms.linux;
  };
}
