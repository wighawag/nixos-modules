# pkgs/kenning-pi.nix
#
# The kenning-pi pi EXTENSION (kenning: sessions that know about each other,
# with the kenning and ralph-loop skills) as a STORE PATH, packaged from its
# published npm tarball exactly like memonaut-pi (see pkgs/memonaut-pi.nix for
# the full rationale): the tarball ships no lockfile, so one is generated from
# it with the dev block STRIPPED and `--legacy-peer-deps`, and kept beside
# this file. A host lists the store path in pi's `packages` instead of an
# `npm:` entry, so session start installs nothing, the version is fixed by the
# flake lock, and it rolls back with the system.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (pi-coding-agent, typebox). pi provides
# them to the extension it loads (its loader aliases its own packages and
# typebox), and pi's own npm install of an extension leaves them out the same
# way (`--legacy-peer-deps`), so this store path has the same layout as
# `npm:kenning-pi@<v>` under ~/.pi/agent/npm.
#
# Nothing is written into the package: kenning's database and spawn logs go to
# $KENNING_STATE_DIR (else $XDG_STATE_HOME/kenning), worktrees to
# ~/dev/worktrees. kenning needs Node >= 22.5 (node:sqlite) in the pi that
# loads it.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/kenning-pi/-/kenning-pi-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/kenning-pi-package-lock.json
#   2. nix store prefetch-file --name kenning-pi-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.2.0",
}:
pkgs.buildNpmPackage {
  pname = "kenning-pi";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/kenning-pi/-/kenning-pi-${version}.tgz";
    hash = "sha256-0DKnoqwo3hESpydEDDI4WeAm4W+g9tre4albSk4fNyI=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./kenning-pi-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-CRJvWT09Z1jSvkXZ9s0DOQLyMXnsehQVMV8r0xFV4t8=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # The tarball is what pi loads as published (`dist/index.js`, `skills/`); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/kenning-pi";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/kenning-pi"
    test -f "$root/package.json" || { echo "kenning-pi: no package.json at $root"; exit 1; }
    test -f "$root/dist/index.js" || { echo "kenning-pi: pi.extensions entry dist/index.js is missing"; exit 1; }
    test -d "$root/skills/kenning" || { echo "kenning-pi: pi.skills entry skills/kenning is missing"; exit 1; }
    test -f "$root/node_modules/kenning/package.json" || { echo "kenning-pi: bundled kenning dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: kenning: sessions that know about each other, with the kenning and ralph-loop skills (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/kenning-pi";
  };
}
