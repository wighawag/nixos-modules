# pkgs/shipmates-pi.nix
#
# The @shipmates/pi pi EXTENSION (shipmates: sessions that know about each
# other, with the shipmates and ralph-loop skills) as a STORE PATH, packaged
# from its published npm tarball exactly like memonaut-pi (see
# pkgs/memonaut-pi.nix for the full rationale): the tarball ships no lockfile,
# so one is generated from it with the dev block STRIPPED and
# `--legacy-peer-deps`, and kept beside this file. A host lists the store path
# in pi's `packages` instead of an `npm:` entry, so session start installs
# nothing, the version is fixed by the flake lock, and it rolls back with the
# system.
#
# shipmates was called kenning (this file was pkgs/kenning-pi.nix, packaging
# kenning-pi 0.2.0): @shipmates/pi 0.3.0 is the same code renamed (shipmates
# spec D38), with no compatibility layer for the old state dir or variables.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (pi-coding-agent, typebox). pi provides
# them to the extension it loads (its loader aliases its own packages and
# typebox), and pi's own npm install of an extension leaves them out the same
# way (`--legacy-peer-deps`), so this store path has the same layout as
# `npm:@shipmates/pi@<v>` under ~/.pi/agent/npm.
#
# Nothing is written into the package: the shipmates database and spawn logs
# go to $SHIPMATES_STATE_DIR (else $XDG_STATE_HOME/shipmates), worktrees to
# ~/dev/worktrees. shipmates needs Node >= 22.5 (node:sqlite) in the pi that
# loads it.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/@shipmates/pi/-/pi-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/shipmates-pi-package-lock.json
#   2. nix store prefetch-file --name pi-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.5.0",
}:
pkgs.buildNpmPackage {
  pname = "shipmates-pi";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@shipmates/pi/-/pi-${version}.tgz";
    hash = "sha256-NkKPNzPjC07vPZF3jtCCmW6ji6MDZkj+I0BxaBGvByA=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./shipmates-pi-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-HbFniLQDw0qpmtHGw5XnNwPjbz9wnoVPDxgsRQwOp1g=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # The tarball is what pi loads as published (`dist/index.js`, `skills/`); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/@shipmates/pi";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/@shipmates/pi"
    test -f "$root/package.json" || { echo "shipmates-pi: no package.json at $root"; exit 1; }
    test -f "$root/dist/index.js" || { echo "shipmates-pi: pi.extensions entry dist/index.js is missing"; exit 1; }
    test -d "$root/skills/shipmates" || { echo "shipmates-pi: pi.skills entry skills/shipmates is missing"; exit 1; }
    test -d "$root/skills/ralph-loop" || { echo "shipmates-pi: pi.skills entry skills/ralph-loop is missing"; exit 1; }
    test -f "$root/node_modules/shipmates/package.json" || { echo "shipmates-pi: bundled shipmates dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: shipmates: sessions that know about each other, with the shipmates and ralph-loop skills (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/@shipmates/pi";
  };
}
