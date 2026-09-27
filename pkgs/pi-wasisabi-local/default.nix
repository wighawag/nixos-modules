# The pi extension that registers the local model server (see index.js).
# Dependency-free, so it is a plain copy into the store with the same
# `extensionSubdir` passthru the other pi extensions here publish: pi resolves
# a local package path with a bare existsSync, so a wrong subpath would cost
# every session its local model SILENTLY. The check below fails the build
# instead.
{ pkgs }:
pkgs.runCommand "pi-wasisabi-local-0.1.0"
  {
    passthru.extensionSubdir = "lib/node_modules/pi-wasisabi-local";
    meta = {
      description = "pi extension: the machine's local model, over its unix socket";
      license = pkgs.lib.licenses.agpl3Only;
    };
  }
  ''
    root=$out/lib/node_modules/pi-wasisabi-local
    install -Dm444 ${./package.json} $root/package.json
    install -Dm444 ${./index.js} $root/index.js
    ${pkgs.nodejs}/bin/node --check $root/index.js
  ''
