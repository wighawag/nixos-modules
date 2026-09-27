# packages/pi-webveil.nix
#
# The pi-webveil EXTENSION (pi's `web_search` / `web_fetch` tools, backed by
# webveil) as a STORE PATH, packaged from its published npm tarball the same way
# the sibling webveil CLI is (see packages/webveil.nix for the full rationale on
# the missing lockfile and the regeneration steps, which apply here verbatim).
#
# WHY THIS EXISTS, given that flake.nix used to say the opposite. The old
# comment read "Pi's pi-webveil extension is deliberately NOT packaged here: Pi
# installs its extensions itself from the settings.json the module renders."
# That was right for the pi-agent SERVICE, whose unit has ordinary egress and
# can npm-install on first use. It is wrong for an ANON ACCOUNT, where every
# fetch crosses the jail: npm over Tor at session start is slow, observable and
# can fail closed. ADR-0017 reverses `packages = []` in modules/anon-home.nix on
# exactly that ground -- the objection was always the npm FETCH, never the
# extension -- which requires the extension to exist as a store path first.
#
# THAT PI ACCEPTS AN ABSOLUTE STORE PATH IS MEASURED, NOT ASSUMED. pi 0.80.6
# parses a settings `packages` entry that is not `npm:`/`git:`/`github:`/`http:`
# /`https:`/`ssh:` as a LOCAL path, and resolving one merely resolves,
# existsSync-checks and returns it: no install, no copy, no write, so a
# read-only /nix/store path works and session start stays fully offline.
# Verified by loading pi-webveil 0.4.0 itself from a store path with zero
# errors. See work/notes/findings/pi-loads-store-path-extensions-and-uwsgi-
# socket-activation-needs-fd3.md.
#
# THE CONSUMER MUST POINT AT `lib/node_modules/pi-webveil`, NOT AT `$out`, and
# this is not cosmetic. The extension's entry point is `src/index.ts` (named by
# the package's own `pi.extensions` manifest) and it does `import ... from
# 'webveil'`, which Node resolves by walking UP from the entry file. buildNpmPackage
# installs dependencies INSIDE the package directory
# (`lib/node_modules/pi-webveil/node_modules/webveil`), so the walk finds them
# from the manifest path and from nowhere else. Pointing at `$out` would resolve
# to a directory with no package.json and contribute nothing -- silently, which
# is the next hazard.
#
# A NON-EXISTENT PATH FAILS SILENTLY, so the CONSUMER must assert. The two
# failure modes are NOT alike, and only one of them is dangerous:
#
#   - path does not exist  -> SILENT. pi's local resolution opens with a bare
#     `if (!existsSync(resolved)) return;`, so there is no warning, no error and
#     exit 0, in a real session as well as in `--help`. The account simply has
#     no `web_search` and no `web_fetch` and nothing says so. For an anon
#     account that is the same "still exists, still looks right" failure
#     ADR-0017 rejects the loopback design over.
#   - path exists but is not a loadable package (pointing at `$out`, say) ->
#     LOUD. A real session prints `Error: Failed to load extension "..."` and a
#     hint. Measured, so nobody adds machinery to catch a case pi already
#     catches.
#
# Since a `${pkgs.pi-webveil}` reference always exists (Nix guarantees the store
# path, and settings.json referencing it makes it a GC dependency), the residual
# risk is a wrong SUBPATH under it: wrong-and-absent is the silent one. The
# assertion therefore checks the FULL path and that it carries a package.json
# with a `pi.extensions` manifest. It lives in modules/anon-home.nix, at the
# point of use, because that is where the subpath is chosen; this file cannot
# check its own consumers.
#
# NO `mainProgram` and no bin: this is a library/extension consumed by path, not
# a CLI. The webveil CLI is the sibling package, and the two are independent
# (installing one does not give you the other).
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces. Kept in lockstep with packages/webveil.nix's version,
  # because pi-webveil depends on webveil EXACTLY (`"webveil": "0.4.0"`, not a
  # range), so a bump on one side that is not mirrored on the other puts two
  # different webveil copies on the box.
  version ? "0.4.0",
}:
pkgs.buildNpmPackage {
  pname = "pi-webveil";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/pi-webveil/-/pi-webveil-${version}.tgz";
    hash = "sha256-ClLiDwifLVZSR10loz57z/ZHhvg0sut1JOgvEiyVsoE=";
  };

  # The lockfile the tarball does not ship, generated from the tarball with
  # pi-webveil as the ROOT package. In postPatch because that is the hook BOTH
  # the dependency fetch and the build run, so the lock the cache was built from
  # and the lock `npm ci` reads stay byte-identical.
  postPatch = ''
    cp ${./pi-webveil-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-a8xI2T2+pJcu0JSAymlOEZi21wJyjCDqZTi7d4ZCFZo=";

  npmFlags = ["--ignore-scripts"];

  # `dist/` is already built in the published tarball; there is no build script
  # to run and running one would need devDependencies (tsc) this install could
  # still fetch but has no reason to execute.
  dontNpmBuild = true;

  # The SUBPATH a consumer must point pi at, published so the path is never
  # spelled by hand. An eval-time `pathExists` check would be useless here (the
  # output does not exist until it is built, so the assertion would fire on
  # every clean eval), and the dangerous failure is a wrong subpath that does
  # not exist, which pi reports by doing nothing at all. Publishing the subdir
  # and asserting it at BUILD time below covers both: the consumer cannot typo
  # it, and the build fails if it ever moves.
  passthru.extensionSubdir = "lib/node_modules/pi-webveil";

  # The three things the consumer depends on, asserted HERE so a bad upstream
  # publish or an npmInstallHook change fails the BUILD rather than silently
  # costing an anon session its web tools (pi says nothing when an extension
  # path resolves to nothing). `src/index.ts` is what `pi.extensions` names, and
  # the nested webveil is what its `import` resolves to.
  postInstall = ''
    root="$out/lib/node_modules/pi-webveil"
    test -f "$root/package.json" || { echo "pi-webveil: no package.json at $root"; exit 1; }
    test -f "$root/src/index.ts" || { echo "pi-webveil: pi.extensions entry src/index.ts is missing"; exit 1; }
    test -f "$root/node_modules/webveil/package.json" || { echo "pi-webveil: bundled webveil dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension registering web_search and web_fetch, backed by webveil (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/pi-webveil";
  };
}
