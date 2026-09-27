# webhands: drive a real browser from the command line (goto, snapshot, click,
# type, eval, screenshot), for agents and for people.
#
# Carried over from the my-boxes fleet (packages/webhands.nix there) with ONE
# deliberate change: the browser. The fleet wraps it with Chrome for Testing,
# Google's own build, which ships the WidevineCdm DRM module and is not free
# software, so it cannot be on a wasisabi machine. This wraps it with nixpkgs'
# `chromium` instead: built from source, BSD-3-Clause, no Widevine.
#
# THE VERSION DOES NOT MATCH, AND THAT WAS MEASURED RATHER THAN ASSUMED:
# webhands 0.8.0 bundles Playwright 1.61.1, which asks for Chromium revision
# 1228 (149), and nixpkgs ships a newer Chromium (152 at the time of writing).
# Driven headless on 2026-09-26 it launched, navigated, returned an
# accessibility snapshot and ran page JavaScript. Playwright talks to Chromium
# over CDP, which is stable across nearby versions; if a future pairing ever
# breaks, the symptom is a launch or protocol error from `webhands serve`.
#
# THE REVISION IS READ, NOT RESTATED: Playwright looks for its browser at
# $PLAYWRIGHT_BROWSERS_PATH/chromium-<revision>/chrome-linux64/chrome, and the
# revision comes from the playwright-core this package bundles, so a webhands
# bump that moves Playwright moves the path with it.
{
  pkgs,
  version ? "0.8.0",
  chromium ? pkgs.chromium,
}:
pkgs.buildNpmPackage (finalAttrs: {
  pname = "webhands";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/webhands/-/webhands-${version}.tgz";
    hash = "sha256-gQKQk/Tl4nWI83OEEw73UOd65ty2+HfFQW7O0H69oSo=";
  };

  # The published tarball ships no lockfile; this one was generated for it.
  postPatch = ''
    cp ${./webhands-package-lock.json} package-lock.json
  '';
  npmDepsHash = "sha256-ipSn2tN1EPVPavBJgbFLJRGpknHGtij7d8aN/84XJZ0=";
  npmFlags = [ "--ignore-scripts" ];
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  dontNpmBuild = true;

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.jq
  ];

  postInstall = ''
    root=$out/lib/node_modules/webhands
    browsersJson=$root/node_modules/playwright-core/browsers.json
    test -f "$browsersJson" || { echo "webhands: no playwright-core/browsers.json"; exit 1; }
    rev() { jq -er --arg n "$1" '.browsers[] | select(.name == $n) | .revision' "$browsersJson"; }

    bp=$out/share/playwright-browsers
    full=$bp/chromium-$(rev chromium)/chrome-linux64
    shell=$bp/chromium_headless_shell-$(rev chromium-headless-shell)/chrome-headless-shell-linux64
    mkdir -p "$full" "$shell"
    ln -s ${chromium}/bin/chromium "$full/chrome"
    # Headless: the same free Chromium. Its --headless is the current headless
    # mode, which is what Playwright's separate headless shell provides.
    ln -s ${chromium}/bin/chromium "$shell/chrome-headless-shell"

    if [ -d "$root/skills" ]; then
      mkdir -p "$out/share/agent-skills"
      cp -r "$root/skills/." "$out/share/agent-skills/"
    fi

    # --set-default: a caller that points at its own browser bundle still can.
    wrapProgram "$out/bin/webhands" --set-default PLAYWRIGHT_BROWSERS_PATH "$bp"
  '';

  passthru = {
    skills = [ "use-webhands" ];
    # The PLAYWRIGHT_BROWSERS_PATH the wrapper sets, for consumers that set it
    # themselves (the anon homes' login environment).
    browsers = "${finalAttrs.finalPackage}/share/playwright-browsers";
  };

  meta = {
    description = "Drive a real browser from the command line (with nixpkgs' free Chromium)";
    homepage = "https://www.npmjs.com/package/webhands";
    license = pkgs.lib.licenses.agpl3Plus;
    mainProgram = "webhands";
  };
})
