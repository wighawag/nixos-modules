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
    # Pinned to the commit tagged wherever-dev@0.20.1 (0.20.0 adds starred
    # sessions, 0.20.1 a faster PWA reconnect), which embeds pi 1.4.0
    # (so the `pi` CLI moves to 1.4.0 with it) and gives web sessions pi's
    # native MCP support. 0.16.0+ is required:
    # unix socket support, the only interface an anon account can serve; and
    # 0.18.1+ for sessions on a model an extension provides (the local model
    # through pi-wabisabi-local: before it, a wherever session came up as
    # `unknown:unknown` while the pi CLI worked). Its
    # server/package.json also decides which pi version the `pi` CLI is built
    # at (pkgs/default.nix).
    wherever = {
      url = "github:wighawag/wherever/757f682f650d10185612c44e721bb724b235e86d";
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
          ./modules/anon-nix-daemon.nix
          ./modules/anon-host-sockets.nix
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
          # are USED (wabisabi's demo VM and its agent-layer check, my-boxes'
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
          # The same host on the searchcast backend: no anonSearch, and the
          # account's webveil.json carries the code recipes, the chain and
          # in-memory state.
          searchcastHost = everything.extendModules {
            modules = [
              {
                nixos-modules.anonSearch.enable = lib.mkForce false;
                nixos-modules.anonHome.webTools = {
                  backend = "searchcast";
                  searchcast = {
                    codeRecipes = [ (pkgs.writeText "web.mjs" "export default {};") ];
                    engines = [ "web" ];
                  };
                };
              }
            ];
          };
          searchcastJson = builtins.fromJSON (
            builtins.unsafeDiscardStringContext
              searchcastHost.config.environment.etc."anon-home/webveil-anon.json".text
          );
          searchcastOk =
            searchcastJson.backend == "searchcast"
            && searchcastJson.egress.mode == "direct"
            && searchcastJson.searchcast.state.persist == false
            && searchcastJson.searchcast.engines == [ "web" ]
            && lib.hasPrefix "/nix/store/" (lib.head searchcastJson.searchcast.codeRecipes)
            && !(searchcastJson ? baseUrl)
            && !(searchcastHost.config.systemd.sockets ? "anon-search-anon");
          # The searchcast backend with no recipes and no chain: webveil's own
          # default chain, which it uses only when the keys are ABSENT (an empty
          # codeRecipes list makes every search fail with "set searchcast.engines").
          defaultChainHost = everything.extendModules {
            modules = [
              {
                nixos-modules.anonSearch.enable = lib.mkForce false;
                nixos-modules.anonHome.webTools.backend = "searchcast";
              }
            ];
          };
          defaultChainJson = builtins.fromJSON (
            builtins.unsafeDiscardStringContext
              defaultChainHost.config.environment.etc."anon-home/webveil-anon.json".text
          );
          defaultChainOk =
            defaultChainJson.backend == "searchcast"
            && defaultChainJson.searchcast == {state.persist = false;};
          # anonSearch with the searchcast backend is refused (its sockets would run unused).
          refusedHost = searchcastHost.extendModules {
            modules = [ { nixos-modules.anonSearch.enable = lib.mkOverride 40 true; } ];
          };
          refusedOk = lib.any (
            a: !a.assertion && lib.hasInfix "nixos-modules.anonHome.webTools.backend" a.message
          ) refusedHost.config.assertions;
        in
        {
          everything-evaluates = pkgs.writeText "nixos-modules-everything" everything.config.system.build.toplevel.drvPath;
          searchcast-backend-evaluates =
            assert searchcastOk;
            pkgs.writeText "nixos-modules-searchcast" searchcastHost.config.system.build.toplevel.drvPath;
          searchcast-default-chain =
            assert defaultChainOk;
            pkgs.writeText "nixos-modules-searchcast-default-chain" "ok";
          searchcast-refuses-anon-search =
            assert refusedOk;
            pkgs.writeText "nixos-modules-searchcast-refuses" "ok";
          reconcile-lint = self.packages.${system}.anon-reconcile;
          routes-guard-lint = self.packages.${system}.caddy-routes-guard;
        };
    };
}
