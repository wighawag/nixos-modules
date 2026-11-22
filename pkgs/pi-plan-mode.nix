# pkgs/pi-plan-mode.nix
#
# The pi-plan-mode pi EXTENSION (a read-only planning mode (/plan)) as a STORE
# PATH, packaged from its published npm tarball exactly like memonaut-pi (see
# pkgs/memonaut-pi.nix for the full rationale): the tarball ships no lockfile,
# so one is generated from it with the dev block STRIPPED and `--legacy-peer-
# deps`, and kept beside this file. A host lists the store path in pi's
# `packages` instead of an `npm:` entry, so session start installs nothing,
# the version is fixed by the flake lock, and it rolls back with the system.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (the `@mariozechner/*` pi names, which pi
# 1.x still aliases). pi provides them to the extension it loads (its loader
# aliases its own packages and typebox), and pi's own npm install of an
# extension leaves them out the same way (`--legacy-peer-deps`), so this store
# path has the same layout as `npm:pi-plan-mode@<v>` under ~/.pi/agent/npm.
#
# It has no dependencies of its own, so the lock holds only the root.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/pi-plan-mode/-/pi-plan-mode-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/pi-plan-mode-package-lock.json
#   2. nix store prefetch-file --name pi-plan-mode-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.4.8",
}:
pkgs.buildNpmPackage {
  pname = "pi-plan-mode";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pi-plan-mode/-/pi-plan-mode-${version}.tgz";
    hash = "sha256-wOmwooaB1bR9bKVN88nPC+eFxr2lVVOeG8F9HHgmkwU=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./pi-plan-mode-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-UKwaYlNVKEarN2vjhvVTkB60Af2nCH3OSZUZVm3iZVo=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # No dependencies, so the npm cache is empty by design; buildNpmPackage
  # refuses an empty cache unless told it is intended.
  forceEmptyCache = true;
  # ...and npmInstallHook walks `node_modules`, which an install with no
  # dependencies never creates.
  preInstall = "mkdir -p node_modules";

  # The tarball is what pi loads as published (`plan-mode.ts`, which pi loads through its TypeScript loader); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/pi-plan-mode";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/pi-plan-mode"
    test -f "$root/package.json" || { echo "pi-plan-mode: no package.json at $root"; exit 1; }
    test -f "$root/plan-mode.ts" || { echo "pi-plan-mode: pi.extensions entry plan-mode.ts is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: a read-only planning mode (/plan) (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/pi-plan-mode";
  };
}
