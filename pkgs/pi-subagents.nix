# pkgs/pi-subagents.nix
#
# The pi-subagents pi EXTENSION (subagents and workflows, run as child pi sessions) as a STORE PATH, packaged from its
# published npm tarball exactly like memonaut-pi (see pkgs/memonaut-pi.nix for
# the full rationale): the tarball ships no lockfile, so one is generated from
# it with the dev block STRIPPED and `--legacy-peer-deps`, and kept beside
# this file. A host lists the store path in pi's `packages` instead of an
# `npm:` entry, so session start installs nothing, the version is fixed by the
# flake lock, and it rolls back with the system.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (pi-coding-agent, pi-ai, pi-tui, pi-agent-core, typebox). pi provides them to the
# extension it loads (its loader aliases its own packages and typebox), and
# pi's own npm install of an extension leaves them out the same way, so this
# store path has the same layout as `npm:pi-subagents@<v>` under ~/.pi/agent/npm.
#
# Its child runners get pi's module aliases from the parent pi (JITI_ALIAS,
# runner-peer-preload.mjs), not from the package directory, so they do not
# need the peers either.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/pi-subagents/-/pi-subagents-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/pi-subagents-package-lock.json
#   2. nix store prefetch-file --name pi-subagents-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.90.0",
}:
pkgs.buildNpmPackage {
  pname = "pi-subagents";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pi-subagents/-/pi-subagents-${version}.tgz";
    hash = "sha256-mf/FM8IR7ZQlsLaUHnUAYVyudxCeaFUbjegz3jmjRgo=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./pi-subagents-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-n7Bcd+IwYcp/3q0I3F8pWQmfYEn5LDBhMw9mzR1CsGM=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # The tarball is what pi loads as published (`bundle/index.js`, `skills/`, `prompts/`); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/pi-subagents";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/pi-subagents"
    test -f "$root/package.json" || { echo "pi-subagents: no package.json at $root"; exit 1; }
    test -f "$root/bundle/index.js" || { echo "pi-subagents: pi.extensions entry bundle/index.js is missing"; exit 1; }
    test -d "$root/skills" || { echo "pi-subagents: pi.skills entry skills/ is missing"; exit 1; }
    test -d "$root/prompts" || { echo "pi-subagents: pi.prompts entry prompts/ is missing"; exit 1; }
    test -f "$root/node_modules/jiti/package.json" || { echo "pi-subagents: bundled jiti dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: subagents and workflows, run as child pi sessions (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/pi-subagents";
  };
}
