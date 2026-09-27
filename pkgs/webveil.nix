# packages/webveil.nix
#
# The webveil CLI (account-free search + fetch for agent shells) as a
# STORE-PATH executable, packaged from its published npm tarball exactly the
# way webhands is (see packages/webhands.nix for the full rationale).
#
# Same story as webhands: the published tarball ships a PREBUILT dist/ and NO
# lockfile, so buildNpmPackage has nothing to build its dependency cache
# from. The lock beside this file is generated once from the tarball itself
# (webveil@0.4.0 as the ROOT package, not as a dependency of a wrapper
# project) and committed, which is what pins the floating ranges (^7.28.0
# undici &c) into a reproducible closure.
#
# Regenerate on a version bump:
#   curl -sL https://registry.npmjs.org/webveil/-/webveil-<v>.tgz | tar xz
#   cd package && npm install --package-lock-only --ignore-scripts
#   cp package-lock.json <this dir>/webveil-package-lock.json
#
# --ignore-scripts is hygiene here rather than load-bearing (no browsers in
# this closure, unlike webhands): the lock's three script-bearing packages
# (@parcel/watcher, esbuild, fsevents) are vitest devDeps whose binaries come
# from platform OPTIONAL packages, so nothing in the install needs to run.
#
# WHY A SYSTEM PACKAGE AT ALL: pi sessions consume webveil through the
# pi-webveil extension, but operators and agents also want the bare CLI on
# PATH — `webveil search` is the fastest end-to-end verification of this
# box's search stack (socket -> SearXNG -> engines -> egress), the same way
# webhands lets a session drive a browser without pi in between.
#
# Bumping is three steps:
#   1. set `version`, regenerate the lockfile as above
#   2. nix store prefetch-file --name webveil-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.4.0",
}:
pkgs.buildNpmPackage {
  pname = "webveil";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/webveil/-/webveil-${version}.tgz";
    hash = "sha256-MzcJXgpiEyr/o8NWuHdG1MA5VcpDkQ70KR2YuG1xKL0=";
  };

  # The lockfile the tarball does not ship. In postPatch because that is the
  # hook BOTH the dependency fetch and the build run, so the lock the cache
  # was built from and the lock `npm ci` reads stay byte-identical.
  postPatch = ''
    cp ${./webveil-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-L4ULNWz5T9u3qKPrr6MRkQ3QHfF9wpSDDAUnQkR88PQ=";

  npmFlags = ["--ignore-scripts"];

  # `dist/` is already built in the published tarball; there is no build script
  # to run and running one would need devDependencies (tsc) this install
  # could still fetch but has no reason to execute.
  dontNpmBuild = true;

  meta = {
    description = "Account-free web search and fetch for agent shells (SearXNG backend, per-hop egress)";
    homepage = "https://www.npmjs.com/package/webveil";
    mainProgram = "webveil";
  };
}
