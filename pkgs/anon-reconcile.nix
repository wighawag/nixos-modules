# packages/anon-reconcile.nix
#
# The reconcile core as a STORE PATH, assembled from scripts/anon-reconcile.sh.
#
# `writeShellApplication` rather than `writeShellScript`, for two properties this
# script specifically needs. It runs shellcheck AT BUILD TIME, so the class of bug
# that shipped in this script's interim predecessor (an unquoted expansion, a
# pipeline whose failure is swallowed) fails the build rather than the box; and it
# pins `runtimeInputs` into PATH, so the script never depends on what happened to
# be on root's PATH when systemd started it.
#
# WHAT IS DELIBERATELY NOT IN runtimeInputs: caddy and anonctl. This fleet builds
# Caddy WITH the Cloudflare DNS plugin (plugins are compile-time in Caddy), so the
# store has exactly one caddy that can adapt this machine's config and it is the
# one the running unit uses; the script resolves it from that unit's ExecStart,
# and a plain nixpkgs caddy here would give it a validator that cannot parse the
# live config, which is worse than none because it would look like it worked.
# anonctl is passed as an explicit PATH argument by the module instead, so the
# binary that decides whether an account is jailed is the same build the host
# declares and deploys rather than whatever a PATH lookup finds.
{pkgs}:
pkgs.writeShellApplication {
  name = "anon-reconcile";

  runtimeInputs = with pkgs; [
    coreutils # head, tr, mktemp, chmod, chown, basename, cat, cksum
    findutils # find -printf, for the ledger listing and the trigger digest
    gnugrep
    gnused
    gawk
    jq # every JSON read and the only JSON write
    util-linux # flock, which serializes two triggers close together
    # getent is NOT called by this script at all, and leaving it out broke the
    # feature on its first real run. ANONCTL shells out to `getent passwd
    # <account>` to resolve a uid (anoncore provision.go), and it inherits this
    # PATH; a systemd service's default path is only coreutils, findutils,
    # gnugrep, gnused and systemd, so nothing else was going to supply it.
    #
    # The failure was not a missing-tool error, which is what makes it worth this
    # comment: anonctl reports an unrunnable getent as `account-missing`, so every
    # managed account was refused as though its passwd entry had vanished, while
    # `id -u anon-01` answered 8802 on the same box. Measured on telemaque
    # 2026-09-24, with the unit's own PATH: `uid: null` and `account-missing`,
    # versus `uid: "8802"` when the same binary can find getent.
    getent
    # nft is NOT called by this script any more (the forced gate is `anonctl
    # probe` since 0.7.0), and it is still required: ANONCTL shells out to nft to
    # read the live ruleset, and it inherits this PATH. Removing it as dead weight
    # would turn every probe into `rules-unreadable`, i.e. every account refused,
    # which is loud and fail-closed but entirely self-inflicted.
    nftables
    systemd # systemctl: unit discovery, socket repair, the caddy reload
  ];

  text = builtins.readFile ../scripts/anon-reconcile.sh;

  meta = {
    description = "Turn anonctl's ledger into per-account wherever-anon state and Caddy routing";
    mainProgram = "anon-reconcile";
  };
}
