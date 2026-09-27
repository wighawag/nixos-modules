{
  lib,
  pkgs,
  nixosModulesSources,
  ...
}:

# The packages the modules run, built against THIS system's pkgs (never this
# repo's own nixpkgs pin). Each is a mkDefault, so a single one can be
# substituted, e.g. `nixos-modules.pkgs.wherever = myWherever;`, and the rest
# are kept.
{
  options.nixos-modules.pkgs = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.package;
    description = ''
      The packages the nixos-modules services run, built against this
      system's pkgs. Override one attribute to substitute a build.
    '';
  };

  # Per attribute, not as an option default: a default is replaced wholesale by
  # any definition, so overriding one package would have dropped all the others.
  config.nixos-modules.pkgs = lib.mapAttrs (_: lib.mkDefault) (
    import ../pkgs {
      inherit pkgs;
      sources = nixosModulesSources;
    }
  );
}
