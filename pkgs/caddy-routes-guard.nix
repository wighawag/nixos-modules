# packages/caddy-routes-guard.nix
#
# The anon-routes guard as a STORE PATH, assembled from
# scripts/caddy-routes-guard.sh. Sibling of packages/anon-reconcile.nix and built
# the same way for the same reasons.
#
# `writeShellApplication` rather than `writeShellScript`: it runs shellcheck AT
# BUILD TIME, and this script runs as ROOT before the machine's web server starts,
# which is the worst place in the fleet to discover an unquoted expansion. It also
# pins runtimeInputs into PATH, so nothing depends on what systemd happened to
# hand the unit.
#
# CADDY IS DELIBERATELY NOT IN runtimeInputs, exactly as in anon-reconcile: this
# fleet builds Caddy WITH the Cloudflare DNS plugin (plugins are compile-time), so
# only one caddy in the store can adapt this machine's config, and it is the one
# the unit runs. The module passes that binary as an explicit argument, and a
# check pins it to the package in the unit's own ExecStart. A plain nixpkgs caddy
# here would be a validator that cannot parse the live config, which is worse than
# none because it would look like it worked.
{pkgs}:
pkgs.writeShellApplication {
  name = "caddy-routes-guard";

  runtimeInputs = with pkgs; [
    coreutils # date, basename, dirname, mkdir, chmod, mv, head
    gnugrep # the one that finds the fragment named in the adapt error
    gnused # escaping the routes dir for that regex
  ];

  text = builtins.readFile ../scripts/caddy-routes-guard.sh;

  meta = {
    description = "Quarantine a Caddy routing fragment that would stop the config adapting, before Caddy starts";
    mainProgram = "caddy-routes-guard";
  };
}
