# packages/memonaut-pi.nix
#
# The memonaut-pi EXTENSION (pi's `recall_search` / `recall_thread` /
# `recall_sql` tools, plus the skill documenting them) as a STORE PATH, for the
# same single reason packages/pi-webveil.nix exists: an ANON account must not
# npm-install anything at session start, because that fetch crosses the jail
# (npm over Tor), which is slow, observable, and can fail closed.
#
# WHY THIS FILE CONTRADICTS packages/memonaut.nix'S COMMENT, which says the
# extension is "deliberately NOT packaged here". That comment is right about
# the OPERATOR, who npm-installs it through services.piUser.settings.packages
# with ordinary egress, and it is the wrong default for a jailed account. Both
# hold at once: the operator keeps the npm install, an anon home gets this store
# path, and the two are the same upstream version by convention rather than by
# construction (nothing links them; a bump is two edits).
#
# WHY MEMONAUT IS ALLOWED IN AN ANON HOME AT ALL, which is the question the
# `skills` option in modules/anon-home.nix used to answer with "it searches the
# operator's past sessions across every project". That objection is about a
# SHARED index, and there is none: memonaut's index is
# `~/.local/share/memonaut/index.db`, per-HOME and 0600 (measured on this box).
# A slot indexes its own sessions in its own home, which nothing else can read,
# and it cannot reach the operator's index because the operator's home is 0700
# and, for the unit that hosts these sessions, not in the filesystem view at
# all. So the tool is exactly as anonymous as the account it runs in.
#
# TWO BINARIES ARE NOT WHAT THIS IS. `memonaut`/`recall` (the CLI) come from
# packages/memonaut.nix; this package ships no bin and is consumed only by
# absolute path from pi's `packages` setting. An anon home gets the TOOLS, not
# the CLI, and that is deliberate: the tools are in-process, so they work in a
# hosted wherever session where the unit's PATH holds no such binary.
#
# THE CONSUMER MUST POINT AT `lib/node_modules/memonaut-pi`, never at `$out`,
# and a wrong subpath fails SILENTLY (pi's local resolution is a bare
# `if (!existsSync(resolved)) return;`). The subdir is therefore PUBLISHED here
# and asserted at BUILD time; see packages/pi-webveil.nix for the full argument
# and the measurement behind it, which applies to this package verbatim.
#
# THE DEV DEPENDENCIES ARE STRIPPED BEFORE THE LOCK IS GENERATED, which the
# sibling packages did not have to do, and the reason is a hard failure rather
# than tidiness. memonaut-pi devDepends on pi ITSELF, and three of pi's own
# sub-packages (`pi-agent-core`, `pi-ai`, `pi-tui`) are published WITHOUT
# integrity metadata, which nixpkgs' `prefetch-npm-deps` refuses outright:
#
#     thread '<unnamed>' panicked at src/parse/mod.rs:171:22:
#     non-git dependencies should have associated integrity
#
# Deleting them is provably free here: `dontNpmBuild` is set because the tarball
# ships `dist/` already built, so nothing in this derivation ever runs tsc or
# vitest. `--legacy-peer-deps` is the second half of the same removal: npm 7+
# INSTALLS peer dependencies by default, and this package's peers are pi and
# typebox, so without that flag deleting the dev block simply pulls the same
# tree back in through the other door. With both, the lock is two entries
# (memonaut-pi and memonaut) and the closure is what an extension actually needs.
#
# Bumping is three steps, as for the siblings:
#   1. set `version`, regenerate the lockfile FROM A STRIPPED MANIFEST:
#        curl -sL https://registry.npmjs.org/memonaut-pi/-/memonaut-pi-<v>.tgz | tar xz
#        cd package
#        node -e 'const f="package.json",p=require("./"+f);delete p.devDependencies;
#                 require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
#        npm install --package-lock-only --ignore-scripts --legacy-peer-deps
#        cp package-lock.json <this dir>/memonaut-pi-package-lock.json
#   2. nix store prefetch-file --name memonaut-pi-<v>.tgz <tarball url>, paste into src.hash
#   3. set npmDepsHash = pkgs.lib.fakeHash, build, paste the `got:` hash back
{
  pkgs,
  # Explicit, never a dist-tag: an upstream publish must not change what a
  # rebuild produces.
  version ? "0.2.0",
}:
pkgs.buildNpmPackage {
  pname = "memonaut-pi";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/memonaut-pi/-/memonaut-pi-${version}.tgz";
    hash = "sha256-bMnf7eE23/eoDy8tNpzroTIybXDzUwrEp2ox2RYVktg=";
  };

  # The lockfile the tarball does not ship, generated from the tarball with
  # memonaut-pi as the ROOT package and its dev block removed (see the header).
  # In postPatch because that is the hook BOTH the dependency fetch and the
  # build run, so the lock the cache was built from and the lock `npm ci` reads
  # stay byte-identical, and so the manifest `npm ci` validates against is the
  # same stripped one the lock was generated from.
  #
  # `jq` is named by ABSOLUTE STORE PATH rather than put in nativeBuildInputs,
  # and that is load-bearing: `postPatch` runs in TWO derivations (this one and
  # the separate npm-deps fetcher), and the fetcher does not inherit this
  # package's build inputs, so a bare `jq` is `command not found` there while
  # looking perfectly correct here.
  postPatch = ''
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.stripped
    mv package.json.stripped package.json
    cp ${./memonaut-pi-package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-rOayEGHOnjtQeBz0e4vjFHIsnjWRRqGR/gBwj7WT5mg=";

  npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];

  # `dist/` is already built in the published tarball, and building it would
  # need the peer dependency on pi itself, which this package must not pull in:
  # the extension is loaded BY a pi that is already running.
  dontNpmBuild = true;

  # The subpath a consumer hands to pi, published so it is never spelled by
  # hand. Same contract as pi-webveil's.
  passthru.extensionSubdir = "lib/node_modules/memonaut-pi";

  # What the consumer depends on, asserted HERE so a bad upstream publish fails
  # the BUILD rather than silently costing an anon session its recall tools.
  # `dist/index.js` is what the package's own `pi.extensions` manifest names,
  # `skills/memonaut` is what `pi.skills` names (which is why no host links that
  # skill separately: pi would report a collision and skip one copy), and the
  # nested memonaut is what the extension's `import` resolves to.
  postInstall = ''
    root="$out/lib/node_modules/memonaut-pi"
    test -f "$root/package.json" || { echo "memonaut-pi: no package.json at $root"; exit 1; }
    test -f "$root/dist/index.js" || { echo "memonaut-pi: pi.extensions entry dist/index.js is missing"; exit 1; }
    test -d "$root/skills/memonaut" || { echo "memonaut-pi: pi.skills entry skills/memonaut is missing"; exit 1; }
    test -f "$root/node_modules/memonaut/package.json" || { echo "memonaut-pi: bundled memonaut dependency is missing"; exit 1; }
  '';

  meta = {
    description = "pi extension registering the recall_* transcript tools, backed by memonaut (consumed by absolute store path, not npm)";
    homepage = "https://www.npmjs.com/package/memonaut-pi";
  };
}
