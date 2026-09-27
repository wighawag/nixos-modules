{
  config,
  lib,
  pkgs,
  ...
}:

# PI FOR THE MACHINE'S OWNER: the coding agent on PATH, its extensions from the
# store, and a starting configuration pointed at the machine's own model.
#
# The laptop-shaped counterpart of the my-boxes fleet's `services.piUser`,
# which DECLARES settings.json (a read-only store symlink) because on a fleet
# the file is policy. On a personal machine it is the owner's, and pi writes to
# it in normal use (a model or theme change from the UI), so here it is SEEDED:
# written once if absent, then left alone. `declareSettings` restores the fleet
# behaviour for a machine that wants it.
#
# THE ONE TRAP A SEED HAS, and how it is avoided: settings.json names
# extensions by PATH, and a seeded file outlives the generation that wrote it.
# A store path written into it would be garbage-collected out from under it
# after an upgrade, and pi's local-package resolution is a bare existsSync, so
# the extension would vanish SILENTLY. So the seed never names a store path: it
# names /etc/wasisabi/pi-extensions/<name>, a symlink every activation repoints
# at the current build. The file stays the owner's; the extensions stay current.
let
  cfg = config.nixos-modules.piUser;
  home = config.users.users.${cfg.user}.home or "/home/${cfg.user}";
  agentDir = "${home}/.pi/agent";

  extDir = "/etc/wasisabi/pi-extensions";
  extensionPaths = lib.mapAttrsToList (name: _: "${extDir}/${name}") cfg.extensions;

  settingsJson = {
    packages = extensionPaths;
  }
  // cfg.settings;
in
{
  options.nixos-modules.piUser = {
    enable = lib.mkEnableOption "the pi coding agent for the machine's owner";

    user = lib.mkOption {
      type = lib.types.str;
      description = "The human whose home pi is configured in.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = config.nixos-modules.pkgs.pi;
      defaultText = lib.literalExpression "config.nixos-modules.pkgs.pi";
      description = ''
        pi, as a store path. Defaults to the version wherever embeds, because
        the CLI and wherever's in-process sessions share one ~/.pi/agent (one
        extension set, pinned for one pi API).
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      description = ''
        pi extensions from the store, by name. Each package must publish the
        `extensionSubdir` passthru (the package root pi should load), which is
        asserted: a wrong subpath would make pi skip the extension silently.
        Exposed at ${extDir}/<name>, which is what settings.json names.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        settings.json content (merged over `packages`, which lists `extensions`).
        Seeded once unless `declareSettings` is true. Must hold no secret: it is
        rendered into the world-readable store.
      '';
    };

    declareSettings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Replace settings.json with a read-only store symlink on every
        activation, instead of seeding it once. Then this configuration is the
        single source of truth, and pi cannot persist a UI change to it.
      '';
    };

    agentsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "A user-global AGENTS.md, linked read-only. Null leaves any existing file alone.";
    };

    webveilConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        ~/webveil.json, which pi-webveil (and the webveil CLI) read to find the
        search backend. DECLARED (a read-only symlink): its content is derived
        from the search service's own options, and a stale backend address
        fails SILENTLY (webveil reports no results, not an error).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    assertions = lib.mapAttrsToList (name: p: {
      assertion = p ? extensionSubdir;
      message = ''
        nixos-modules.piUser.extensions.${name} does not publish the
        `extensionSubdir` passthru, so there is no way to know which directory
        pi should load. pi would skip it without a word.
      '';
    }) cfg.extensions;

    environment.etc =
      lib.mapAttrs' (
        name: p:
        lib.nameValuePair "wasisabi/pi-extensions/${name}" { source = "${p}/${p.extensionSubdir}"; }
      ) cfg.extensions
      // {
        "wasisabi/pi-seed/settings.json".text = builtins.toJSON settingsJson;
      }
      // lib.optionalAttrs (cfg.webveilConfig != { }) {
        "wasisabi/pi-seed/webveil.json".text = builtins.toJSON cfg.webveilConfig;
      };

    systemd.tmpfiles.rules = [
      "d ${home}/.pi 0700 ${cfg.user} users -"
      "d ${agentDir} 0700 ${cfg.user} users -"
      # `C` from the STORE path (not the /etc symlink, which `C` would copy as
      # a symlink): a real, writable file the owner then owns.
      (
        if cfg.declareSettings then
          "L+ ${agentDir}/settings.json - - - - ${
            config.environment.etc."wasisabi/pi-seed/settings.json".source
          }"
        else
          "C ${agentDir}/settings.json 0600 ${cfg.user} users - ${
            config.environment.etc."wasisabi/pi-seed/settings.json".source
          }"
      )
    ]
    # A copy out of the store is root-owned and 0444; `z` hands it to the owner
    # as a writable file. Applied every boot, which only ever re-asserts what
    # the owner already has.
    ++ lib.optionals (!cfg.declareSettings) [
      "z ${agentDir}/settings.json 0600 ${cfg.user} users -"
    ]
    ++ lib.optionals (cfg.agentsFile != null) [
      "L+ ${agentDir}/AGENTS.md - - - - ${cfg.agentsFile}"
    ]
    ++ lib.optionals (cfg.webveilConfig != { }) [
      "L+ ${home}/webveil.json - - - - ${config.environment.etc."wasisabi/pi-seed/webveil.json".source}"
    ];
  };
}
