# Build with the same pkgs and Home Manager library used by the consuming configuration.
{ pkgs, homeManager }:
let
  inherit (pkgs) lib;
  package = pkgs.runCommand "noctalia-starship-test-assets" { } ''
    mkdir -p $out/share/noctalia/assets/templates/starship
    cp -r ${../../assets/templates/starship}/. $out/share/noctalia/assets/templates/starship
  '';
  evaluate =
    extra:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ../../nix/home-module.nix
        {
          home.username = "starship-test";
          home.homeDirectory = "/tmp/noctalia-starship-module-test";
          home.stateVersion = "26.05";
          programs.noctalia = {
            enable = true;
            inherit package;
            checkConfig = false;
            starship.enable = lib.mkDefault true;
          };
          programs.starship = {
            enable = lib.mkDefault true;
            validateFiles.config = false;
          };
        }
        extra
      ];
    }).config;
  settings = {
    programs.starship = {
      presets = [ "plain-text-symbols" ];
      settings = {
        format = "{{literal}} $directory$character";
        directory.truncation_length = 7;
        palette = "original";
        palettes.original.blue = "#123456";
      };
    };
  };
  rawSettings = "[theme]\nmode = 'dark'";
  raw = evaluate {
    programs.noctalia.starship.enable = false;
    programs.noctalia.settings = rawSettings;
  };
  fromPath = evaluate {
    programs.noctalia.starship.enable = false;
    programs.noctalia.settings = ../../assets/templates/starship/starship.toml;
  };
  configured = evaluate settings;
  updated = evaluate (
    lib.recursiveUpdate settings {
      programs.starship.settings.directory.truncation_length = 11;
    }
  );
  empty = evaluate { };
  disabled = evaluate (
    settings
    // {
      programs.noctalia.starship.enable = false;
    }
  );
  failures =
    extra: map (a: a.message) (builtins.filter (a: !a.assertion) (evaluate extra).assertions);
  rejects = extra: !(builtins.tryEval (evaluate extra)).success;
  configFile = c: c.xdg.configFile."noctalia/config.toml".source;
in
assert failures { } == [ ];
assert rejects { programs.starship.enable = lib.mkForce false; };
assert rejects { programs.noctalia.package = lib.mkForce null; };
assert rejects { programs.noctalia.settings = "[theme]\nmode = 'dark'"; };
assert rejects {
  programs.starship.configPath = "/tmp/noctalia-starship-module-test/.local/state/noctalia/starship.toml";
};
assert rejects { programs.starship.configPath = ".local/state/noctalia/starship.toml"; };
assert rejects {
  programs.noctalia.settings.theme.templates.starship_config = "/tmp/other-starship.toml";
};
assert rejects { programs.noctalia.settings.theme.templates.user.starship.input_path = "custom"; };
assert rejects {
  programs.noctalia.settings.theme.templates = {
    builtin_ids = [ "starship" ];
  };
};
assert disabled.home.sessionVariables.STARSHIP_CONFIG == disabled.programs.starship.configPath;
assert !(disabled.home.activation ? noctaliaStarship);
assert !(disabled.xdg.configFile ? "noctalia/config.toml");
assert
  (evaluate {
    programs.noctalia.starship.enable = false;
    programs.noctalia.settings = "[theme]\nmode = 'dark'";
  }).programs.noctalia.settings == "[theme]\nmode = 'dark'";
pkgs.runCommand "noctalia-starship-module-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 - <<'PY'
  import os
  from pathlib import Path
  import shlex
  import subprocess
  import tomllib

  configs = [Path(p) for p in ["${configFile configured}", "${configFile updated}", "${configFile empty}"]]
  base = Path("${configured.home.file.${configured.programs.starship.configPath}.source}")
  original = base.read_bytes()
  assert Path("${configFile raw}").read_text() == "[theme]\nmode = 'dark'"
  assert Path("${configFile fromPath}").read_bytes() == Path("${../../assets/templates/starship/starship.toml}").read_bytes()
  output = Path("${configured.home.sessionVariables.STARSHIP_CONFIG}")
  palette = Path("${configured.xdg.cacheHome}/noctalia/starship-palette.toml")
  os.environ["STARSHIP_CONFIG"] = str(base)

  def compose(config):
      templates = tomllib.loads(config.read_text())["theme"]["templates"]
      assert templates["starship_config"] == str(output)
      template = templates["user"]["starship"]
      assert template["hook_async"] is False
      subprocess.run(shlex.split(template["post_hook"]), check=True)

  compose(configs[0])
  assert output.read_bytes() == original
  assert not output.is_symlink()
  assert output.stat().st_mode & 0o200
  assert not base.stat().st_mode & 0o222
  inode, mtime = output.stat().st_ino, output.stat().st_mtime_ns
  compose(configs[0])
  assert (output.stat().st_ino, output.stat().st_mtime_ns) == (inode, mtime)

  palette.parent.mkdir(parents=True, exist_ok=True)
  palette.write_text('[palettes.noctalia]\nblue = "#112233"\n')
  compose(configs[0])
  actual = tomllib.loads(output.read_text())
  expected = tomllib.loads(original.decode())
  expected["palette"] = "noctalia"
  expected["palettes"]["noctalia"] = {"blue": "#112233"}
  assert actual == expected

  compose(configs[1])
  actual = tomllib.loads(output.read_text())
  assert actual["directory"]["truncation_length"] == 11
  assert actual["palettes"]["noctalia"]["blue"] == "#112233"
  palette.write_text('[palettes.noctalia]\nblue = "#445566"\n')
  compose(configs[1])
  assert tomllib.loads(output.read_text())["palettes"]["noctalia"]["blue"] == "#445566"
  assert base.read_bytes() == original
  assert not list(output.parent.glob("starship.toml.*"))

  palette.unlink()
  compose(configs[2])
  assert output.read_text() == ""
  palette.write_text('[palettes.noctalia]\nblue = "#778899"\n')
  compose(configs[2])
  assert tomllib.loads(output.read_text()) == {"palette": "noctalia", "palettes": {"noctalia": {"blue": "#778899"}}}
  PY
  touch $out
''
