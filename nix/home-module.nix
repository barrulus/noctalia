{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.noctalia;
  jsonFormat = pkgs.formats.json { };
  tomlFormat = pkgs.formats.toml { };

  generateConfig =
    format: name: value:
    if lib.isString value then
      pkgs.writeText name value
    else if builtins.isPath value || lib.isStorePath value then
      value
    else
      format.generate name value;

  generateToml = generateConfig tomlFormat;
  generateJson = generateConfig jsonFormat;

  starship = config.programs.starship;
  starshipConfigPath =
    if lib.hasPrefix "/" starship.configPath then
      starship.configPath
    else
      "${config.home.homeDirectory}/${starship.configPath}";
  starshipOutput = "${config.xdg.stateHome}/noctalia/starship.toml";
  starshipAssets = "${cfg.package}/share/noctalia/assets/templates/starship";
  starshipBase =
    if starship.settings == { } && starship.presets == [ ] then
      pkgs.writeText "starship.toml" ""
    else
      config.home.file.${starship.configPath}.source;
  composeStarship = pkgs.writeShellApplication {
    name = "noctalia-compose-starship";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnused
      gnugrep
      bash
    ];
    text = ''
      output=${lib.escapeShellArg starshipOutput}
      mkdir -p "$(dirname "$output")"
      temporary=$(mktemp "$output.XXXXXX")
      trap 'rm -f "$temporary"' EXIT
      cat ${lib.escapeShellArg starshipBase} > "$temporary"
      export XDG_CACHE_HOME=${lib.escapeShellArg config.xdg.cacheHome}
      if [[ -f "$XDG_CACHE_HOME/noctalia/starship-palette.toml" ]]; then
        STARSHIP_CONFIG="$temporary" bash ${lib.escapeShellArg "${starshipAssets}/apply.sh"}
      fi
      if ! cmp -s "$temporary" "$output"; then
        mv -f "$temporary" "$output"
      fi
    '';
  };
  settings =
    if cfg.starship.enable && lib.isAttrs cfg.settings && cfg.package != null then
      lib.recursiveUpdate cfg.settings {
        theme.templates.starship_config = starshipOutput;
        theme.templates.user.starship = {
          input_path = "${starshipAssets}/starship.toml";
          output_path = "${config.xdg.cacheHome}/noctalia/starship-palette.toml";
          post_hook = lib.escapeShellArg (lib.getExe composeStarship);
          hook_async = false;
        };
      }
    else
      cfg.settings;
in
{
  # Disable the home-manager module to avoid conflicts
  # The module got turned into a folder on 2026-09-30. Disable both old and new.
  disabledModules = [
    "programs/noctalia.nix"
    "programs/noctalia"
  ];

  imports = [
    (lib.mkRenamedOptionModule
      [ "programs" "noctalia" "validateConfig" ]
      [ "programs" "noctalia" "checkConfig" ]
    )
  ];

  options.programs.noctalia = {
    enable = lib.mkEnableOption "noctalia, a lightweight Wayland shell and bar";

    systemd.enable = lib.mkEnableOption "a systemd user service for noctalia";

    starship.enable = lib.mkEnableOption "Noctalia colors for Home Manager's Starship configuration";

    package = lib.mkPackageOption pkgs "noctalia" { nullable = true; };

    checkConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Validate the configuration file at build time.";
    };

    settings = lib.mkOption {
      type =
        with lib.types;
        oneOf [
          tomlFormat.type
          str
          path
        ];
      default = { };
      description = ''
        Default settings for noctalia, Can be written as:
          - A Nix attrset (converted to TOML via nixpkgs' tomlFormat)
          - A raw TOML string
          - A path to a `.toml` file

        See <https://docs.noctalia.dev/noctalia/configuration/> for more information and examples.

        Note: these settings can still be overwritten at runtime via the settings menu.
      '';
      example = lib.literalExpression ''
        shell = {
          font = "JetBrainsMono Nerd Font";
          settings_show_advanced = true;
        };

        theme = {
          mode = "dark";
          source = "builtin";
          builtin = "Catppuccin";
        };
      '';
    };

    customPalettes = lib.mkOption {
      type =
        with lib.types;
        attrsOf (oneOf [
          jsonFormat.type
          str
          path
        ]);
      default = { };
      description = ''
        Custom color pallete options.

        See <https://docs.noctalia.dev/noctalia/theming/palette/#custom-palette-files>.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.noctalia = lib.mkIf cfg.systemd.enable {
      Unit = {
        Description = "Noctalia - A lightweight Wayland shell and bar";
        Documentation = "https://docs.noctalia.dev/noctalia/";
        PartOf = [ config.wayland.systemd.target ];
        After = [ config.wayland.systemd.target ];
        X-Restart-Triggers =
          lib.optional (settings != { }) "${config.xdg.configFile."noctalia/config.toml".source}"
          ++ lib.mapAttrsToList (
            name: _: "${config.xdg.configFile."noctalia/palettes/${name}.json".source}"
          ) cfg.customPalettes;
      };

      Service = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
      };

      Install.WantedBy = [ config.wayland.systemd.target ];
    };

    home.packages = lib.optional (cfg.package != null) cfg.package;

    home.sessionVariables.STARSHIP_CONFIG = lib.mkIf cfg.starship.enable (lib.mkForce starshipOutput);
    home.activation.noctaliaStarship = lib.mkIf (cfg.starship.enable && cfg.package != null) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe composeStarship}
      ''
    );

    xdg = {
      configFile = lib.mkMerge [
        (lib.mkIf (settings != { }) {
          "noctalia/config.toml".source =
            let
              rawConfig = generateToml "config.toml" settings;
            in
            if cfg.checkConfig && cfg.package != null then
              pkgs.runCommand "noctalia-config.toml" { } ''
                ${lib.getExe cfg.package} config validate ${rawConfig}
                cp ${rawConfig} $out
              ''
            else
              rawConfig;
        })
        (lib.mapAttrs' (
          name: palette:
          lib.nameValuePair "noctalia/palettes/${name}.json" {
            source = generateJson "${name}-palette.json" palette;
          }
        ) cfg.customPalettes)
      ];
    };

    assertions = [
      {
        assertion = !cfg.starship.enable || starship.enable;
        message = "programs.noctalia.starship.enable requires programs.starship.enable";
      }
      {
        assertion = !cfg.starship.enable || cfg.package != null;
        message = "programs.noctalia.starship.enable requires a non-null programs.noctalia.package";
      }
      {
        assertion = !cfg.starship.enable || lib.isAttrs cfg.settings;
        message = "programs.noctalia.starship.enable requires programs.noctalia.settings to be an attribute set";
      }
      {
        assertion = !cfg.starship.enable || /. + starshipConfigPath != /. + starshipOutput;
        message = "programs.starship.configPath must differ from Noctalia's generated Starship output";
      }
      {
        assertion =
          !cfg.starship.enable
          || !lib.isAttrs cfg.settings
          || builtins.elem (cfg.settings.theme.templates.starship_config or "") [
            ""
            starshipOutput
          ];
        message = "programs.noctalia.starship.enable manages theme.templates.starship_config; remove the conflicting path";
      }
      {
        assertion =
          !cfg.starship.enable
          || !lib.isAttrs cfg.settings
          || !(cfg.settings ? theme.templates.user.starship);
        message = "programs.noctalia.starship.enable manages theme.templates.user.starship; remove the custom entry";
      }
      {
        assertion =
          !cfg.starship.enable
          || !lib.isAttrs cfg.settings
          || !(cfg.settings.theme.templates.enable_builtin_templates or true)
          || !(builtins.elem "starship" (cfg.settings.theme.templates.builtin_ids or [ ]));
        message = "programs.noctalia.starship.enable replaces the built-in Starship template; disable that template";
      }
      {
        assertion = !cfg.systemd.enable || cfg.package != null;
        message = "programs.noctalia.package cannot be null when programs.noctalia.systemd.enable is true";
      }
    ];
  };

  _class = "homeManager";
}
