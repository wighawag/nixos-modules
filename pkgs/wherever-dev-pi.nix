# pkgs/wherever-dev-pi.nix
#
# The @wherever-dev/pi pi EXTENSION (wherever's CLI bridge: a terminal pi
# driven from a wherever server) as a STORE PATH, packaged from its published
# npm tarball exactly like memonaut-pi (see pkgs/memonaut-pi.nix for the full
# rationale): the tarball ships no lockfile, so one is generated from it with
# the dev block STRIPPED and `--legacy-peer-deps`, and kept beside this file.
# A host lists the store path in pi's `packages` instead of an `npm:` entry,
# so session start installs nothing, the version is fixed by the flake lock,
# and it rolls back with the system.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (pi-coding-agent, typebox). pi provides
# them to the extension it loads (its loader aliases its own packages and
# typebox), and pi's own npm install of an extension leaves them out the same
# way (`--legacy-peer-deps`), so this store path has the same layout as
# `npm:@wherever-dev/pi@<v>` under ~/.pi/agent/npm.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/@wherever-dev/pi/-/pi-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/wherever-dev-pi-package-lock.json
#   2. nix store prefetch-file --name pi-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.8.0",
}:
pkgs.buildNpmPackage {
  pname = "wherever-dev-pi";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@wherever-dev/pi/-/pi-${version}.tgz";
    hash = "sha256-npaOAjS+e+DiLxfSa5bB7CNN52tvmLBHh8sqiuawWQY=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./wherever-dev-pi-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-aa/Xg23YSlGdlnLb7MUc76RVVMbMB8MLLYctFX4lKrw=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # The tarball is what pi loads as published (`dist/index.js`); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/@wherever-dev/pi";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/@wherever-dev/pi"
    test -f "$root/package.json" || { echo "@wherever-dev/pi: no package.json at $root"; exit 1; }
    test -f "$root/dist/index.js" || { echo "@wherever-dev/pi: pi.extensions entry dist/index.js is missing"; exit 1; }
    test -f "$root/node_modules/@wherever-dev/client/package.json" || { echo "@wherever-dev/pi: bundled @wherever-dev/client dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: wherever's CLI bridge: a terminal pi driven from a wherever server (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/@wherever-dev/pi";
  };
}
