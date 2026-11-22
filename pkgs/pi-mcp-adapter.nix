# pkgs/pi-mcp-adapter.nix
#
# The pi-mcp-adapter pi EXTENSION (MCP servers as pi tools (the `mcp` gateway, direct tools, OAuth)) as a STORE PATH, packaged from its
# published npm tarball exactly like memonaut-pi (see pkgs/memonaut-pi.nix for
# the full rationale): the tarball ships no lockfile, so one is generated from
# it with the dev block STRIPPED and `--legacy-peer-deps`, and kept beside
# this file. A host lists the store path in pi's `packages` instead of an
# `npm:` entry, so session start installs nothing, the version is fixed by the
# flake lock, and it rolls back with the system.
#
# THE PEERS ARE LEFT OUT ON PURPOSE (pi-ai, pi-tui, typebox; zod is also a regular dependency, so it is installed). pi provides them to the
# extension it loads (its loader aliases its own packages and typebox), and
# pi's own npm install of an extension leaves them out the same way, so this
# store path has the same layout as `npm:pi-mcp-adapter@<v>` under ~/.pi/agent/npm.
#
# Its native optional dependencies (@napi-rs/keyring for OAuth tokens in the
# OS keyring, recheck's regex checker) are npm's prebuilt binaries for the
# platform, unpatched, exactly as pi's npm install gets them, so this store
# path behaves as `npm:pi-mcp-adapter@<v>` does on the same machine.
#
# Bumping is three steps, as for memonaut-pi:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/pi-mcp-adapter/-/pi-mcp-adapter-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/pi-mcp-adapter-package-lock.json
#   2. nix store prefetch-file --name pi-mcp-adapter-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "7.0.1",
}:
pkgs.buildNpmPackage {
  pname = "pi-mcp-adapter";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pi-mcp-adapter/-/pi-mcp-adapter-${version}.tgz";
    hash = "sha256-Koz8tEuQE98v8EGeUZGfGqA6O7/cPiCzdHHRXtUhWjo=";
  };

  # Same hook and same absolute `jq` as memonaut-pi, for the same reason (the
  # npm-deps fetcher runs postPatch too and does not inherit build inputs).
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./pi-mcp-adapter-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-527AKVOQm4/4pddoa5GYWnq5goHcazpAR+1bTs1Ck+U=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # The tarball is what pi loads as published (`index.ts`, which pi loads through its TypeScript loader); nothing to build.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/pi-mcp-adapter";

  # What pi's manifest names, asserted at BUILD time: a missing entry would
  # otherwise only show up as a session without the extension's tools.
  postInstall = ''
    root="$out/lib/node_modules/pi-mcp-adapter"
    test -f "$root/package.json" || { echo "pi-mcp-adapter: no package.json at $root"; exit 1; }
    test -f "$root/index.ts" || { echo "pi-mcp-adapter: pi.extensions entry index.ts is missing"; exit 1; }
    test -f "$root/node_modules/@modelcontextprotocol/client/package.json" || { echo "pi-mcp-adapter: bundled MCP client dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension: MCP servers as pi tools (the `mcp` gateway, direct tools, OAuth) (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/pi-mcp-adapter";
  };
}
