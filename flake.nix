{
  description = "NixOS modules and packages for agent machines: a local model, private search, pi, wherever, anonctl-jailed anonymous accounts, and an interactive bash";

  inputs = {
    # Only for building the packages and running the checks HERE. The modules
    # take `pkgs` from whichever system imports them, so a consumer should
    # make this follow its own nixpkgs (it then never evaluates this pin).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The wherever server (a web UI driving pi agent sessions), as SOURCE: its
    # `package.nix` is a plain function of pkgs, so it builds against the
    # consumer's nixpkgs instead of dragging its own pin into every closure.
    # Pinned to the commit tagged wherever-dev@0.18.1. 0.16.0+ is required:
    # unix socket support, the only interface an anon account can serve; and
    # 0.18.1+ for sessions on a model an extension provides (the local model
    # through pi-wasisabi-local: before it, a wherever session came up as
    # `unknown:unknown` while the pi CLI worked). Its
    # server/package.json also decides which pi version the `pi` CLI is built
    # at (pkgs/default.nix).
    wherever = {
      url = "github:wighawag/wherever/14f259641f44630b72430035cac1c275b2901ae4";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      wherever,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # The package set as a module, KEYED so that importing several of the
      # outputs below (each of which needs it) includes it once. The source
      # trees are injected here, so the pin lives in this flake's lock and a
      # consumer wires nothing.
      pkgsModule = {
        key = "nixos-modules#pkgs";
        imports = [ ./modules/pkgs.nix ];
        _module.args.nixosModulesSources = { inherit wherever; };
      };

      moduleOf = files: { imports = [ pkgsModule ] ++ files; };
    in
    {
      # Every module is inert until its own `enable` is set, so importing
      # `default` (all of them) costs nothing and is the simple choice. The
      # per-area outputs exist for a consumer that wants a smaller surface.
      nixosModules = {
        default = moduleOf [ ./modules ];
        llm = moduleOf [ ./modules/llm.nix ];
        searxng = moduleOf [ ./modules/searxng.nix ];
        piUser = moduleOf [ ./modules/pi-user.nix ];
        wherever = moduleOf [ ./modules/wherever.nix ];
        interactiveShell = moduleOf [ ./modules/interactive-shell.nix ];
        # The anon accounts refer to each other's options (accounts, socket
        # paths, the dispatcher's routes), and anon-home also reads piUser's,
        # so they come as one.
        anon = moduleOf [
          ./modules/pi-user.nix
          ./modules/anon-accounts.nix
          ./modules/anonctl-units.nix
          ./modules/anon-dns.nix
          ./modules/anon-home.nix
          ./modules/anon-search.nix
          ./modules/wherever-anon.nix
          ./modules/wherever-anon-reconcile.nix
          ./modules/anon-dispatcher.nix
        ];
      };

      # The packages, built against this repo's pin so they can be built and
      # cached on their own (`nix build .#anonctl`). The modules build the same
      # files against the importing system's pkgs.
      packages.${system} = import ./pkgs {
        inherit pkgs;
        sources = { inherit wherever; };
      };

      checks.${system} =
        let
          # Everything on at once, on a throwaway machine: every module
          # evaluates, the anon stack's cross-module assertions hold, and the
          # packages it references build. Behaviour is tested where the modules
          # are USED (wasisabi's demo VM and its agent-layer check, my-boxes'
          # hosts); this only proves the repo stands on its own.
          everything = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                fileSystems."/" = {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                };
                boot.loader.grub.enable = false;
                system.stateVersion = lib.trivial.release;
                users.users.owner.isNormalUser = true;
                services.tor = {
                  enable = true;
                  client.enable = true;
                };
                nixos-modules = {
                  llm.enable = true;
                  searxng.enable = true;
                  interactiveShell.enable = true;
                  piUser = {
                    enable = true;
                    user = "owner";
                  };
                  wherever = {
                    enable = true;
                    user = "owner";
                  };
                  anonAccounts = {
                    enable = true;
                    accounts.anon = {
                      uid = 8801;
                      shimUid = 412;
                    };
                  };
                  anonctlUnits = {
                    enable = true;
                    package = self.packages.${system}.anonctl;
                  };
                  anonDns.enable = true;
                  anonHome = {
                    enable = true;
                    models = [
                      {
                        id = "m";
                        name = "m";
                      }
                    ];
                    defaultModel = "m";
                    webTools = {
                      enable = true;
                      package = self.packages.${system}.pi-webveil;
                    };
                  };
                  anonSearch.enable = true;
                  whereverAnon = {
                    enable = true;
                    reconcile.enable = true;
                  };
                  anonDispatcher.enable = true;
                };
              }
            ];
          };
        in
        {
          everything-evaluates = pkgs.writeText "nixos-modules-everything" everything.config.system.build.toplevel.drvPath;
          reconcile-lint = self.packages.${system}.anon-reconcile;
          routes-guard-lint = self.packages.${system}.caddy-routes-guard;
        };
    };
}
