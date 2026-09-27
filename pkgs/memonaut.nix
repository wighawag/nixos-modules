# packages/memonaut.nix
#
# The transcript-recall CLI as a STORE-PATH executable, packaged from its
# published npm tarball like the other operator tools here.
#
# Zero dependencies, so this takes the simple route (plain mkDerivation plus a
# wrapper) rather than buildNpmPackage: there is nothing to resolve, so no
# lockfile is needed and none is missed. Contrast packages/webhands.nix, which
# has a 136-package closure and therefore carries a committed lock.
#
# TWO BINARIES, one entry point. Upstream declares `memonaut` and `recall` as
# separate bins pointing at the same `dist/cli.js`; both are wrapped here so
# either name works, because the tooling and the docs disagree about which to
# use and there is no reason to make the operator care.
#
# RELATED BUT SEPARATE: `memonaut-pi` is the PI EXTENSION, not this. It is
# listed in services.piUser.settings.packages and Pi installs it itself from
# npm at session start, so it is deliberately NOT packaged here (the same rule
# the flake states for Pi's pi-webveil extension). That install is what was
# silently failing on telemaque until nodejs landed: Pi's extension directory
# held only a scaffold, so every session ran with no extensions at all, which
# is why `recall_search` reported no index.
#
# Bumping is two steps:
#   1. set `version`
#   2. nix store prefetch-file --name memonaut-<v>.tgz \
#        https://registry.npmjs.org/memonaut/-/memonaut-<v>.tgz
#      and paste the printed hash into `src.hash`
{
  pkgs,
  # Explicit, never a dist-tag.
  version ? "0.4.0",
}:
pkgs.stdenv.mkDerivation {
  pname = "memonaut";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/memonaut/-/memonaut-${version}.tgz";
    hash = "sha256-0VLk0hHjxhuXwV1X3dKwZ5h3YH7MDfjostbsRggaoW0=";
  };

  nativeBuildInputs = [pkgs.makeWrapper];

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/memonaut
    cp -r . $out/lib/memonaut/

    # Wrapped, not shebang-patched, so the interpreter is THIS nodejs from the
    # closure rather than whatever a session happens to have on PATH.
    for name in memonaut recall; do
      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/$name \
        --add-flags $out/lib/memonaut/dist/cli.js
    done

    # The SKILL this tool ships, at a predictable path so a host can symlink
    # it into ~/.agents/skills/ declaratively. A skill that ships WITH a
    # versioned tool should follow that tool's version rather than being a
    # symlink into a dev checkout: there is nothing to author here, and pinning
    # them together means the skill can never describe a different version than
    # the binary beside it.
    if [ -d "$out/lib/memonaut/skills" ]; then
      mkdir -p "$out/share/agent-skills"
      cp -r "$out/lib/memonaut/skills/." "$out/share/agent-skills/"
    fi

    runHook postInstall
  '';

  meta = {
    description = "Search past AI conversation transcripts (also installed as `recall`)";
    homepage = "https://www.npmjs.com/package/memonaut";
    mainProgram = "memonaut";
  };
}
