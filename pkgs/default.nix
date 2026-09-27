# The packages wasisabi's agent layer runs, built against WHICHEVER nixpkgs
# imports the modules (never this repo's own pin), exactly like every other
# package the module layers reference.
#
# Most of these files were carried over from the my-boxes fleet repo, where
# they run on a real machine (telemaque); their headers keep the reasoning and
# the bump recipes they were written with. References in those headers to
# `work/notes/...`, `hosts/...` or an ADR number point into that repository
# (github.com/wighawag/my-boxes), not this one.
#
# `sources` carries the flake inputs that are consumed as plain trees rather
# than as flakes (see flake.nix for why each one is `flake = false`).
{ pkgs, sources }:

let
  lib = pkgs.lib;

  # wherever builds from its own `package.nix`, a plain function of pkgs, so it
  # is built against the consumer's nixpkgs and does not drag in a second one.
  wherever = import "${sources.wherever}/package.nix" { inherit pkgs; };

  # THE PI VERSION IS READ, NOT RESTATED. wherever hosts agent sessions
  # in-process, so the Pi that answers the web UI is the copy inside the
  # wherever package. The `pi` CLI and those sessions share ONE ~/.pi/agent
  # (settings, extensions, sessions), and extensions are pinned for one Pi API,
  # so the CLI must be the same version wherever embeds. A range upstream
  # fails loudly in pi.nix's knownVersions lookup rather than resolving to
  # something untested.
  whereverPiVersion =
    (lib.importJSON "${sources.wherever}/server/package.json")
    .dependencies."@earendil-works/pi-coding-agent";
in
{
  inherit wherever;
  pi = import ./pi.nix {
    inherit pkgs;
    version = whereverPiVersion;
  };
  anonctl = import ./anonctl.nix { inherit pkgs; };
  anon-reconcile = import ./anon-reconcile.nix { inherit pkgs; };
  caddy-routes-guard = import ./caddy-routes-guard.nix { inherit pkgs; };
  webveil = import ./webveil.nix { inherit pkgs; };
  pi-webveil = import ./pi-webveil.nix { inherit pkgs; };
  memonaut = import ./memonaut.nix { inherit pkgs; };
  memonaut-pi = import ./memonaut-pi.nix { inherit pkgs; };
  pi-wasisabi-local = import ./pi-wasisabi-local { inherit pkgs; };
  webhands = import ./webhands.nix { inherit pkgs; };
}
