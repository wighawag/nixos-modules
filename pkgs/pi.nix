# services/pi-agent/pi.nix
#
# The Pi coding agent as a STORE-PATH executable (resolved-decision 4): the
# brain the broker next door drives. Pi is third-party (published on npm), but
# it is packaged HERE, beside its only consumer, because it is the pi-agent
# service's runtime, not a fleet-wide tool: `services/pi-agent/` owns both
# halves of that service's closure (this file = Pi, package.nix = the broker).
#
# Built from Pi's PUBLISHED npm tarball at a pinned version plus the
# `npm-shrinkwrap.json` that tarball ships, which pins Pi's whole dependency
# closure exactly the way `uv.lock` pins the voice agent's Python one. Nothing
# is fetched at eval/build beyond this pinned tarball and the deps the
# shrinkwrap names (their content-addressed cache is `npmDepsHash` below), so
# the build is reproducible and offline after the fixed-output fetches.
#
# Bumping Pi is one version string and three hash refreshes, in this order:
#   1. set `version`, then `nix store prefetch-file --name pi-coding-agent-<v>.tgz <url>`
#      and paste the result into `src.hash`;
#   2. refresh the three sibling `integrity` values in `postPatch` (the command
#      is in its comment below);
#   3. set `npmDepsHash = pkgs.lib.fakeHash;`, run `nix build .#pi-coding-agent`
#      and paste the `got:` hash back.
{
  pkgs,
  # The pinned Pi version. Explicit (never a dist-tag) so the module's rendered
  # settings, this shrinkwrap and the store path all agree, and so an upstream
  # publish can never change what a rebuild produces.
  #
  # MUST be a key of `knownVersions` below, because every version needs its own
  # four hashes. Passing an unlisted one fails at eval with the bump recipe
  # rather than building something unverified.
  version ? "0.82.1",
}: let
  # THE HASH TABLE, one row per version this repo can build.
  #
  # Two rows rather than one because the fleet deliberately runs TWO Pis, for
  # two consumers that share nothing:
  #
  #   0.80.6  the OPERATOR's Pi (services.piUser). Pinned to whatever
  #           wherever's server/package.json declares, because wherever hosts
  #           agent sessions IN-PROCESS and both it and the `pi` CLI read the
  #           same ~/.pi/agent: one settings.json, one npm extension tree, one
  #           session store. Extensions are pinned for ONE Pi's API, so those
  #           two disagreeing is how a subagent launch dies at the first call
  #           (see work/notes/observations/two-pis-...). flake.nix READS that
  #           version rather than restating it, and a check asserts the match.
  #
  #   0.82.1  box-01's VOICE BROKER (services.piAgent). Independent on purpose:
  #           that box runs no wherever and no piUser, and its Pi lives in its
  #           own DynamicUser state dir at 0700 with its own extension install,
  #           so there is nothing on it to be coherent WITH. Coupling it to
  #           wherever's lockfile would mean a wherever bump forces a
  #           revalidation of the phone line for no reason. Couple where there
  #           is sharing; pin independently where there is not.
  #
  # ADDING A ROW is the bump recipe in the header, done once per version.
  knownVersions = {
    "0.82.1" = {
      srcHash = "sha256-g0OrlcurV2by9dSIRN+NsT53Lq0uKXYWbLuCCinay30=";
      npmDepsHash = "sha256-pTI6uXLZj+NZwjn0sI11cm/gKPMDYZGGbbivGEjyBiI=";
      siblings = {
        pi-agent-core = "sha512-Z3kloziJIE2dmrisRckZX8zDca/gIv9/YdFAzeoqpHiLV2wsni6bL4hInNSjVKLbqT+4kqLIkph2JQLKvSepjg==";
        pi-ai = "sha512-3WFYRhEp3lQB3444EhPMBcM7zSaEUE3eJgHOR7s4081NLqbw/FsWilIKWXSua0Gv3sRr7m9xMidR3pPDE7jI/A==";
        pi-tui = "sha512-9yN8hALfKaxZq7n54EMxqhFCWnMi6LHkraMJ/1YjHiATq75XrI6XDMVppn9EDtiK7Fks8hUe1SDXUTrIvwRWfQ==";
      };
    };
    "0.80.6" = {
      srcHash = "sha256-KndjRkCy2G2Q0kCHu2dVns8jZuD7UqQsVe7UFhR9pBE=";
      npmDepsHash = "sha256-xwn6zBV6QmLPaf9Ht2y1smJSUTMw1DYmPFBvPGVgvCc=";
      siblings = {
        pi-agent-core = "sha512-Lvn89ko42h5ETUb6Z0Ku6ldskEqXaTdQBYvSa0+7bdG9V6rUEpXptv5e0OVZ1HDcvi8s6/2lGCQWsxKX+DFHNw==";
        pi-ai = "sha512-7xfLk8sANBp+bpPEbjoOZTbPxsa+++b1JXAoSJsNa3vbs9AHHEclmvg54XLQcxH+fuwaeti/g2jeIfJ+mVYLpA==";
        pi-tui = "sha512-bSuzS4EVSqEPj/Qr/p9eqCESfKsGuDNbl77EGci8Iaqqt/C/XCBZL1MjXaxSWW1NsT5afjp/Cb0NTPzOLv/aPA==";
      };
    };
  };

  pinned =
    knownVersions.${
      version
    }
    or (throw ''
      services/pi-agent/pi.nix: no hashes recorded for Pi ${version}.
      Add a row to `knownVersions` using the bump recipe in this file's header:
        1. nix store prefetch-file --name pi-coding-agent-${version}.tgz \
             https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz
        2. curl -sS https://registry.npmjs.org/@earendil-works%2F<pkg> \
             | jq -r '.versions["${version}"].dist.integrity'   (per sibling)
        3. set npmDepsHash to lib.fakeHash, build, paste the `got:` value.
    '');
in
  pkgs.buildNpmPackage (finalAttrs: {
    pname = "pi-coding-agent";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
      hash = pinned.srcHash;
    };

    # UPSTREAM FIXUPS, both of them consequences of how Pi's tarball is
    # published. They live in `postPatch` because that is the one hook BOTH the
    # dependency fetch and the build run, so the lockfile the cache was built
    # from and the lockfile `npm ci` reads stay byte-identical.
    #
    # (1) MISSING INTEGRITY. Pi's shrinkwrap omits the `integrity` field for the
    # three packages Pi publishes in lockstep with itself (its generator leaves
    # the workspace siblings unhashed). Nix's prefetcher refuses a registry
    # dependency it cannot verify ("non-git dependencies should have associated
    # integrity"), so the published hashes are pasted back in here, one per
    # sibling, at THIS version. Each is the registry's own `dist.integrity` for
    # that tarball, so this RESTORES the pinning upstream intended rather than
    # relaxing it. Re-fetch on every version bump:
    #   curl -sS https://registry.npmjs.org/@earendil-works%2F<pkg> \
    #     | jq -r '.versions["<version>"].dist.integrity'
    postPatch = let
      siblings = pinned.siblings;
      # JSON is whitespace-insensitive, so the missing key is appended to the
      # `resolved` line it belongs to rather than reindented into the object.
      addIntegrity = name: integrity: let
        resolved = ''"resolved": "https://registry.npmjs.org/@earendil-works/${name}/-/${name}-${finalAttrs.version}.tgz",'';
      in ''
        substituteInPlace npm-shrinkwrap.json \
          --replace-fail ${pkgs.lib.escapeShellArg resolved} ${pkgs.lib.escapeShellArg ''${resolved} "integrity": "${integrity}",''}
      '';
      # (2) PRODUCTION-ONLY LOCKFILE vs a manifest that still lists dev deps.
      # The shrinkwrap Pi publishes covers production dependencies only, so a
      # plain `npm ci` tries to resolve the devDependencies the lockfile does not
      # pin and the build dies ENOTCACHED on the first one. `--omit=dev` does NOT
      # fix it (npm validates manifest against lockfile BEFORE applying the
      # omission), so the dev deps are dropped from the manifest -- truthful for
      # a tarball that ships a PREBUILT `dist/`: nothing here compiles Pi.
      #
      # jq is invoked by STORE PATH rather than from PATH because this same
      # postPatch runs inside the dependency-fetch derivation, which carries no
      # stdenv toolchain.
      dropDevDependencies = ''
        ${pkgs.lib.getExe pkgs.jq} 'del(.devDependencies)' package.json > package.json.pruned
        mv package.json.pruned package.json
      '';
    in
      pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList addIntegrity siblings)
      + dropDevDependencies;

    # The hash of Pi's shrinkwrapped dependency cache. One per version, recorded
    # in `knownVersions` above (see the header for how to obtain it).
    npmDepsHash = pinned.npmDepsHash;

    # Pi's engine floor is Node >= 22.19, ABOVE the fleet's pinned nixpkgs
    # (24.05, Node 22.10) -- which is why this whole file is evaluated against
    # nixpkgs-recent (see the input's note in flake.nix). The major is pinned
    # rather than tracking that input's default `nodejs`, so a nixpkgs-recent
    # update cannot silently move Pi (and the broker, which loads Pi's SDK
    # IN-PROCESS and therefore shares this interpreter) onto a new Node major.
    # Re-exported as `passthru.nodejs` below.
    #
    # WHY 24 AND NOT THE 22 THIS FILE FIRST PINNED: `pi-webveil`, the extension
    # that registers the ONLY tools the fleet's agent is allowed to use
    # (`web_search` / `web_fetch`, see modules/pi-agent.nix), constructs a
    # `URLPattern` at module scope. That global does not exist in Node 22 at all
    # (no flag turns it on there); it ships as a global from Node 24. On 22 the
    # extension fails to load ("Failed to load extension: URLPattern is not
    # defined") and the agent ends up with NO tools at all, silently -- see
    # work/notes/observations/pi-webveil-needs-urlpattern-node22-cannot-load-it-2026-07-26.md.
    # So the floor for THIS fleet is not Pi's >= 22.19 but webveil's >= 24.
    nodejs = pkgs.nodejs_24;

    # The published tarball ships a PREBUILT `dist/` (Pi builds at publish time,
    # with a toolchain -- tsgo/bun -- that is not in this closure). So there is
    # nothing to compile here: install the package and its pruned production
    # deps, nothing more.
    dontNpmBuild = true;

    # Flags for EVERY npm invocation the hooks make (`ci`, `pack`, `prune`), and
    # both of these have to hold at every one of them:
    #
    # `--ignore-scripts`: no lifecycle scripts run. Two packages in the closure
    # declare install scripts (`@google/genai`, `protobufjs`); neither produces
    # anything Pi needs at runtime, and running arbitrary postinstalls is exactly
    # the kind of unpinned, possibly network-touching step this packaging exists
    # to avoid.
    #
    # `--omit=optional`: drop Pi's ONE optional dependency
    # (`@mariozechner/clipboard`), a per-platform prebuilt native module for
    # interactive clipboard support -- this Pi is driven headlessly by the broker
    # on a server, and keeping it would put an unpatched, foreign-libc ELF in the
    # fleet's closure for a feature nothing here can use. Pi imports it
    # defensively (`dist/utils/clipboard-native` resolves to null when absent),
    # so its absence is a supported state, not a broken install.
    #
    # This flag MUST live here and not in `npmInstallFlags`: that one only
    # reaches `npm ci`, and the install hook's later `npm prune --omit=dev`
    # re-reifies the tree WITHOUT the omission and puts the optional deps back
    # (visibly, as an "added 3 packages" line in the build log). Verify after a
    # bump that the store path really has no `node_modules/@mariozechner`.
    npmFlags = ["--ignore-scripts" "--omit=optional"];

    passthru = {
      # The interpreter Pi (and the broker) run on. The sibling `services.piAgent`
      # module needs the MATCHING `npm` -- Pi shells out to it to install its
      # extension packages -- so it reads the major from here instead of pinning a
      # second one of its own.
      inherit (finalAttrs) nodejs;

      # WHERE the broker points its two Pi knobs (see services/pi-agent/README.md
      # "Config"). Exposed as passthru so the sibling `services.piAgent` module
      # writes `${pi.sdkModule}` / `${pi.cliPath}` instead of hardcoding Pi's
      # internal layout -- when Pi moves an entry point, this file is the one
      # place that changes.
      #
      # sdkModule: the ES module specifier the backends `import()`
      #   (`PI_AGENT_SDK_MODULE`), i.e. Pi's package entry point.
      sdkModule = "${finalAttrs.finalPackage}/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js";
      # cliPath: the CLI ENTRY SCRIPT Pi's own `RpcClient` spawns as
      #   `node <path>` (`PI_AGENT_PI_CLI_PATH`, required by the `rpc` backend).
      #   NOT `bin/pi`, which is a shell wrapper `RpcClient` cannot exec as a
      #   node script.
      cliPath = "${finalAttrs.finalPackage}/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js";
    };

    meta = {
      description = "Pi coding agent (the pi-agent service's brain), pinned from its published npm tarball";
      homepage = "https://www.npmjs.com/package/@earendil-works/pi-coding-agent";
      mainProgram = "pi";
      platforms = ["x86_64-linux"];
    };
  })
