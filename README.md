# nixos-modules

NixOS modules and packages for machines that run AI agents: a local model, private search, the pi coding agent and its web UI, anonymous accounts whose every packet is forced through Tor, and an interactive bash. Each module is inert until its own `enable` is set.

Used by [wasisabi](https://github.com/wighawag/wasisabi), which switches them on with sensible defaults for a desktop machine, and by the my-boxes fleet. Most of them were first built for, and run on, real machines in that fleet; their comments keep that history.

## Modules

| Output | Options | What it is |
|---|---|---|
| `llm` | `nixos-modules.llm` | llama.cpp on the CPU (Gemma 4 E4B by default), serving a unix socket from a unit with no network, optionally started on first use |
| `searxng` | `nixos-modules.searxng` | a local SearXNG on a unix socket, socket-activated |
| `piUser` | `nixos-modules.piUser` | pi for a machine's owner, extensions from the store |
| `wherever` | `nixos-modules.wherever` | wherever (a web UI for pi sessions) on loopback, token minted on the machine |
| `anon` | `nixos-modules.anon*`, `.whereverAnon`, `.anonDispatcher` | anonctl-jailed anonymous accounts, each with its own pi home, SearXNG, browser and wherever, routed by a loopback-only Caddy |
| `interactiveShell` | `nixos-modules.interactiveShell` | ble.sh, fzf, zoxide, atuin and a starship powerline prompt in /etc/bashrc, one Catppuccin palette |
| `default` | all of the above | |

The packages they run (`anonctl`, `pi`, `wherever`, `webveil`, `pi-webveil`, `memonaut`, `memonaut-pi`, `webhands`, `pi-wasisabi-local`, ...) are built against the importing system's pkgs and exposed as `config.nixos-modules.pkgs`; override one attribute to substitute your own build. They are also flake `packages` for building on their own.

## Using it

```nix
inputs.nixos-modules = {
  url = "github:wighawag/nixos-modules";
  inputs.nixpkgs.follows = "nixpkgs";
};
# ...
modules = [ nixos-modules.nixosModules.default ];
```

then enable what you want, e.g. `nixos-modules.llm.enable = true;`. See wasisabi's `modules/agents.nix` for how the pieces are wired together, and its `notes/agents.md` for the design and what has been verified.

## License

AGPL-3.0-only.
