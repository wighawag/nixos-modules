# Every module in this repo, each inert until its own `enable` is set. The
# package set (./pkgs.nix) is added by the flake, which injects the source
# trees it builds from.
#
# The options live under `nixos-modules.*` rather than `services.*`, so they
# cannot collide with nixpkgs or with a consumer's own modules of the same
# purpose. Several were first built in the my-boxes fleet repo, where they run
# on a real machine; their comments keep that history, and references to
# `work/notes/...`, `hosts/...` or ADR numbers point into that repository.
{
  imports = [
    ./llm.nix
    ./searxng.nix
    ./pi-user.nix
    ./wherever.nix
    ./anon-accounts.nix
    ./anonctl-units.nix
    ./anon-dns.nix
    ./anon-nix-daemon.nix
    ./anon-home.nix
    ./anon-search.nix
    ./wherever-anon.nix
    ./wherever-anon-reconcile.nix
    ./anon-dispatcher.nix
    ./interactive-shell.nix
  ];
}
