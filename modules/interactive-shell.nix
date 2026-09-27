# modules/services/interactive-shell.nix
#
# Carried over from the my-boxes fleet (modules/interactive-shell.nix there,
# live on telemaque) with the option renamed to nixos-modules.interactiveShell.
# `hosts/nono` and `modules/anon-home.nix` below are that repo's paths (the anon
# homes are ./anon-home.nix here). The only other change is that the flake
# check pinning the init order now reads the demo host's /etc/bashrc.
#
# The interactive bash stack: ble.sh (line editor: syntax highlighting,
# autosuggestions), fzf (Ctrl-T, Alt-C, `**` completion), zoxide (`z`), atuin
# (Ctrl-R history search) and starship (prompt). Bash stays the login shell; no
# framework (oh-my-bash, bash-it) is involved.
#
# BOX-WIDE, for every user, through /etc/bashrc. There is no per-user ~/.bashrc
# on these hosts, and home-manager is deliberately not used for it: it is
# per-user (every account would need its own), it would write rc files into the
# anon homes that modules/anon-home.nix already owns, and it tracks master
# while the hosts track a release (see the fzf skew noted in hosts/nono).
#
# WHY NOT THE UPSTREAM NIXOS MODULES (programs.fzf, programs.atuin,
# programs.starship, programs.zoxide, programs.bash.blesh), checked against the
# 26.05 sources rather than assumed:
#   - programs.fzf.keybindings lands in promptPluginInit, spliced into bash.nix's
#     own block, while atuin and zoxide are separate interactiveShellInit
#     definitions at the same priority. Whether atuin ends up AFTER fzf (and so
#     owns Ctrl-R) would depend on module import order. Nothing pins it.
#   - programs.bash.blesh sources ble.sh WITHOUT --noattach and never calls
#     ble-attach, which is the load order ble.sh itself recommends against.
#   - programs.atuin exports ATUIN_CONFIG_DIR=/etc/atuin to everyone (so a
#     user's ~/.config/atuin is silently ignored) and starts a per-user daemon.
# So this module installs the packages and writes ONE explicitly ordered init,
# split across the two ends of programs.bash.interactiveShellInit:
#
#   mkBefore (before bash.nix's own block):  1. ble.sh --noattach
#   mkAfter  (after everything else, including environment.interactiveShellInit):
#                                            2. fzf  3. zoxide  4. atuin
#                                            5. starship  (in ghostty: its shell
#                                            integration)  6. ble-attach
#
# fzf is also told NOT to bind Ctrl-R at all (FZF_CTRL_R_COMMAND set but empty,
# the switch fzf's own bash integration reads). The ordering alone did hand
# Ctrl-R to atuin when tested; this makes it not depend on atuin overwriting
# fzf's `bind -x` cleanly, and says "fzf, but not Ctrl-R" outright. atuin
# still comes after fzf. atuin detects
# ble.sh natively, so there is no bash-preexec. Atuin keeps the Up arrow as
# plain bash history (--disable-up-arrow) and gets no settings: sync stays off
# until a user runs `atuin login` themselves. Atuin AI is off too
# (--disable-ai): since 18.15 atuin otherwise binds `?`, and at an empty prompt
# that key opens an assistant backed by atuin's online service. The flake check
# `agent-layer` claims pin this order in the demo host's generated
# /etc/bashrc.
#
# ble.sh needs ~/.cache and ~/.local/state to EXIST (it will not create them,
# and falls back to its read-only store directory); the init creates them, and
# skips only ble.sh when a home is not writable.
#
# COLOURS: one palette, Catppuccin Mocha, for every piece that draws colour, so
# the prompt, the command line, fzf and `ls` agree. Each piece is given its
# colours as 24-bit hex (not the 16 named ANSI colours), so it looks the same
# whatever palette the user's terminal has; setting the terminal itself to
# Catppuccin Mocha makes everything else (git, compilers) match too.
#   - starship: the stock `catppuccin-powerline` preset, vendored verbatim in
#     modules/starship-catppuccin-powerline.toml, with the box's overrides
#     merged on top here (hostname over ssh only, no Node version, a NixOS logo,
#     no desktop notifications on a headless box). It is written to
#     /etc/starship.toml and pointed at with STARSHIP_CONFIG only when the
#     user has not set that already. Its powerline shapes and icons need a
#     Nerd Font in the user's terminal.
#   - ble.sh: `ble-face` overrides for the syntax-highlighting faces (its
#     defaults are 256-colour indices picked for a light background, e.g. the
#     autosuggestion on a light grey block). Filenames follow LS_COLORS.
#   - fzf: the Catppuccin FZF_DEFAULT_OPTS colours, minus `bg`, so fzf keeps the
#     terminal's own background. Only when FZF_DEFAULT_OPTS is unset.
#   - ls, fd, tree, ...: LS_COLORS from `vivid generate catppuccin-mocha`, done
#     at build time. Set after NixOS's own `dircolors` (programs.bash.enableLsColors),
#     which it replaces.
#
# GATE: interactive AND a terminal that can draw. `TERM=dumb` is what agent
# tool shells, Emacs M-x shell and scripted ssh sessions report; ble.sh cannot
# render there, and loading atuin there would record agents' commands into the
# user's history. Real terminals (emulators, ssh, zellij, vterm) get it all.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nixos-modules.interactiveShell;

  # starship: the vendored preset, plus this box's overrides.
  starshipPreset = builtins.fromTOML (builtins.readFile ./starship-catppuccin-powerline.toml);
  starshipConfig = (pkgs.formats.toml {}).generate "starship.toml" (lib.recursiveUpdate starshipPreset {
    # The preset has no hostname segment; add one in the user's red block.
    format = builtins.replaceStrings ["$username"] ["$username$hostname"] starshipPreset.format;
    hostname = {
      ssh_only = true;
      style = "bg:red fg:crust";
      format = "[@$hostname]($style)";
    };
    nodejs.disabled = true;
    # The preset has no NixOS entry, so it would fall back to starship's emoji.
    # U+F313 is the Nerd Font NixOS logo (Nix strings have no \u escape).
    os.symbols.NixOS = builtins.fromJSON ''"\uf313"'';
    # A headless box has no desktop to notify.
    cmd_duration.show_notifications = false;
  });

  # THE LINUX TEXT CONSOLE (TERM=linux) gets a different prompt: starship's
  # stock `plain-text-symbols` preset (vendored verbatim beside the other one,
  # from starship 1.26.0), with the same overrides as above that are not about
  # glyphs. The kernel console draws from bitmap fonts of at most 512 glyphs in
  # 16 colours, so the powerline shapes, the Nerd Font icons and the 24-bit
  # palette cannot all be drawn there, whatever font is loaded; it showed as a
  # row of boxes. This keeps the same information (user, host over ssh,
  # directory, git state, duration) in ASCII and named colours. A console that
  # can draw them (kmscon) reports another TERM and gets the full prompt.
  starshipConsoleConfig = (pkgs.formats.toml {}).generate "starship-console.toml" (lib.recursiveUpdate
    (builtins.fromTOML (builtins.readFile ./starship-plain-text-symbols.toml))
    {
      nodejs.disabled = true;
      cmd_duration.show_notifications = false;
    });

  lsColors = pkgs.runCommand "ls-colors-catppuccin-mocha" {} ''
    ${lib.getExe pkgs.vivid} generate catppuccin-mocha > $out
  '';

  # Catppuccin Mocha, https://catppuccin.com/palette
  c = {
    red = "#f38ba8";
    maroon = "#eba0ac";
    peach = "#fab387";
    yellow = "#f9e2af";
    green = "#a6e3a1";
    teal = "#94e2d5";
    sky = "#89dceb";
    blue = "#89b4fa";
    lavender = "#b4befe";
    mauve = "#cba6f7";
    pink = "#f5c2e7";
    flamingo = "#f2cdcd";
    rosewater = "#f5e0dc";
    text = "#cdd6f4";
    subtext0 = "#a6adc8";
    overlay0 = "#6c7086";
    surface2 = "#585b70";
    surface1 = "#45475a";
    surface0 = "#313244";
    crust = "#11111b";
  };

  bleFaces = {
    auto_complete = "fg=${c.overlay0}";
    disabled = "fg=${c.overlay0}";
    region = "bg=${c.surface1}";
    region_target = "bg=${c.surface2}";
    region_match = "bg=${c.surface0}";
    region_insert = "fg=${c.blue},bg=${c.surface0}";
    overwrite_mode = "fg=${c.crust},bg=${c.sky}";
    prompt_status_line = "fg=${c.text},bg=${c.surface0}";
    cmdinfo_cd_cdpath = "fg=${c.crust},bg=${c.green}";

    syntax_command = "fg=${c.green}";
    syntax_quoted = "fg=${c.yellow}";
    syntax_quotation = "fg=${c.yellow},bold";
    syntax_escape = "fg=${c.pink}";
    syntax_expr = "fg=${c.peach}";
    syntax_error = "fg=${c.crust},bg=${c.red}";
    syntax_varname = "fg=${c.flamingo}";
    syntax_param_expansion = "fg=${c.maroon}";
    syntax_history_expansion = "fg=${c.crust},bg=${c.peach}";
    syntax_function_name = "fg=${c.mauve},bold";
    syntax_comment = "fg=${c.overlay0}";
    syntax_glob = "fg=${c.pink},bold";
    syntax_brace = "fg=${c.teal},bold";
    syntax_tilde = "fg=${c.lavender},bold";
    syntax_document = "fg=${c.subtext0}";
    syntax_document_begin = "fg=${c.subtext0},bold";

    command_builtin_dot = "fg=${c.blue},bold";
    command_builtin = "fg=${c.blue}";
    command_alias = "fg=${c.teal}";
    command_function = "fg=${c.mauve}";
    command_file = "fg=${c.green}";
    command_keyword = "fg=${c.mauve}";
    command_jobs = "fg=${c.red},bold";
    command_directory = "fg=${c.blue},underline";

    filename_directory = "underline,fg=${c.blue}";
    filename_directory_sticky = "underline,fg=${c.crust},bg=${c.blue}";
    filename_link = "underline,fg=${c.teal}";
    filename_orphan = "underline,fg=${c.red}";
    filename_executable = "underline,fg=${c.green}";
    filename_warning = "underline,fg=${c.red}";
    filename_url = "underline,fg=${c.blue}";

    varname_unset = "fg=${c.red}";
    varname_empty = "fg=${c.teal}";
    varname_number = "fg=${c.peach}";
    varname_expr = "fg=${c.mauve},bold";
    varname_array = "fg=${c.peach},bold";
    varname_hash = "fg=${c.green},bold";
    varname_readonly = "fg=${c.pink}";
    varname_transform = "fg=${c.teal},bold";
    varname_export = "fg=${c.pink},bold";

    argument_option = "fg=${c.sky}";
    argument_error = "fg=${c.red},underline";
  };

  # Faces defined by ble.sh's completion module, which loads lazily; setting them
  # before it has loaded fails with "face not found".
  bleCompleteFaces = {
    menu_filter_input = "fg=${c.crust},bg=${c.yellow}";
  };
  faceArgs = faces: lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") faces);

  fzfColors = lib.concatStringsSep "," [
    "fg:${c.text}"
    "fg+:${c.text}"
    "bg+:${c.surface0}"
    "hl:${c.red}"
    "hl+:${c.red}"
    "info:${c.mauve}"
    "prompt:${c.mauve}"
    "pointer:${c.rosewater}"
    "marker:${c.lavender}"
    "spinner:${c.rosewater}"
    "header:${c.red}"
    "border:${c.overlay0}"
    "label:${c.text}"
    "selected-bg:${c.surface1}"
  ];
in {
  options.nixos-modules.interactiveShell.enable = lib.mkEnableOption "the interactive bash stack (ble.sh, fzf, zoxide, atuin, starship) for every user";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.blesh
      pkgs.fzf
      pkgs.zoxide
      pkgs.atuin
      pkgs.starship
      pkgs.vivid
    ];

    environment.etc."starship.toml".source = starshipConfig;
    environment.etc."starship-console.toml".source = starshipConsoleConfig;

    programs.bash.interactiveShellInit = lib.mkMerge [
      (lib.mkBefore ''
        # interactive-shell: 1. ble.sh first, attached last (see the end of this file)
        if [[ $- == *i* && ''${TERM-dumb} != dumb ]]; then
          __interactive_shell=1
          # ble.sh uses the XDG cache/state dirs ONLY if they already exist, and
          # otherwise falls back to its own (read-only, store) directory and
          # fails to load. Create them; if the home is not writable, skip ble.sh
          # rather than print an error on every shell (the rest still loads).
          mkdir -p -- "''${XDG_CACHE_HOME:-$HOME/.cache}" "''${XDG_STATE_HOME:-$HOME/.local/state}" 2>/dev/null
          if [[ -w ''${XDG_CACHE_HOME:-$HOME/.cache} ]]; then
            source ${pkgs.blesh}/share/blesh/ble.sh --noattach
            if [[ ''${BLE_VERSION-} ]]; then
              ble-face ${faceArgs bleFaces}
              blehook/eval-after-load complete 'ble-face ${faceArgs bleCompleteFaces}'
            fi
          fi
        fi
      '')
      (lib.mkAfter ''
        # interactive-shell: 2. fzf  3. zoxide  4. atuin (owns Ctrl-R)  5. starship  (ghostty's integration)  6. ble-attach
        if [[ -n ''${__interactive_shell-} ]]; then
          unset __interactive_shell
          # Colours (see COLOURS above). LS_COLORS replaces NixOS's dircolors.
          LS_COLORS=$(<${lsColors}); export LS_COLORS
          [[ ''${BLE_VERSION-} ]] && bleopt filename_ls_colors="$LS_COLORS"
          export FZF_DEFAULT_OPTS=''${FZF_DEFAULT_OPTS-"--color=${fzfColors}"}
          if [[ $TERM == linux ]]; then
            export STARSHIP_CONFIG=''${STARSHIP_CONFIG-/etc/starship-console.toml}
          else
            export STARSHIP_CONFIG=''${STARSHIP_CONFIG-/etc/starship.toml}
          fi
          # Empty (not unset) FZF_CTRL_R_COMMAND makes fzf skip its Ctrl-R binding.
          FZF_CTRL_R_COMMAND=
          eval "$(${lib.getExe pkgs.fzf} --bash)"
          unset FZF_CTRL_R_COMMAND
          eval "$(${lib.getExe pkgs.zoxide} init bash)"
          eval "$(${lib.getExe pkgs.atuin} init bash --disable-up-arrow --disable-ai)"
          eval "$(${lib.getExe pkgs.starship} init bash)"
          # GHOSTTY'S SHELL INTEGRATION, LOADED HERE rather than injected. Its
          # automatic injection sources this file from inside its own startup
          # and installs its prompt hooks AFTER, and ble.sh, seeing the
          # injection, defers attaching to the first prompt: bash then draws
          # the first prompt itself and ble.sh draws it again below, so every
          # new ghostty window opened on a doubled prompt. Sourced before
          # ble-attach it is just another prompt hook and ble.sh attaches
          # normally. Needs `shell-integration = none` in ghostty's config
          # (which still exports the resources dir and the feature list); an
          # injected startup is left to ghostty, so this never loads twice.
          if [[ $TERM == xterm-ghostty && -n ''${GHOSTTY_RESOURCES_DIR-} && -z ''${__ghostty_bash_flags+x} ]] &&
             [[ -r $GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash ]]; then
            builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"
          fi
          [[ ''${BLE_VERSION-} ]] && ble-attach
        fi
      '')
    ];
  };
}
