#include "config/config_service.h"
#include "core/deferred_call.h"
#include "core/toml.h"
#include "tests/test_check.h"
#include "theme/palette.h"
#include "theme/template_apply_service.h"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>
#include <utility>

namespace {

  void writeFile(const std::filesystem::path& path, std::string_view text) {
    std::ofstream out(path);
    out << text;
    TEST_CHECK(out.good());
  }

  std::string readFile(const std::filesystem::path& path) {
    std::ifstream in(path);
    TEST_CHECK(in.good());
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
  }

  void writeConfig(const std::filesystem::path& root, bool enabled, const std::string& path = {}) {
    toml::table templates{{"builtin_ids", enabled ? toml::array{"starship"} : toml::array{}}};
    if (!path.empty()) {
      templates.insert("starship_config", path);
    }
    const toml::table config{{"theme", toml::table{{"templates", std::move(templates)}}}};
    std::ofstream out(root / "config" / "noctalia" / "config.toml");
    out << config;
    TEST_CHECK(out.good());
  }

  void apply(ConfigService& config) {
    bool complete = false;
    noctalia::theme::TemplateApplyService service(config);
    service.setAfterApplyCallback([&](std::string_view, bool) { complete = true; });
    service.apply(noctalia::theme::GeneratedPalette{}, "dark", /*force=*/true);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!complete && std::chrono::steady_clock::now() < deadline) {
      for (auto& call : DeferredCall::takePending()) {
        call();
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    TEST_CHECK(complete);
  }

} // namespace

int main(int argc, char** argv) {
  TEST_CHECK(argc == 2);
  const std::filesystem::path assets = argv[1];
  const auto root = std::filesystem::temp_directory_path() / ("noctalia-starship-" + std::to_string(::getpid()));
  std::filesystem::create_directories(root / "config" / "noctalia");
  std::filesystem::create_directories(root / "state" / "noctalia");
  std::filesystem::create_directories(root / "assets" / "templates" / "starship");
  std::filesystem::create_directories(root / "assets" / "fonts");
  std::filesystem::create_directories(root / "assets" / "translations");
  writeFile(root / "assets" / "emoji.json", "[]");
  writeFile(root / "assets" / "fonts" / "noctalia-tabler.ttf", "");
  writeFile(root / "assets" / "translations" / "en.json", "{}");

  // Exercise the shipped hook commands and scripts; the input palette itself is
  // static because this regression concerns config selection and undo ownership.
  std::filesystem::copy_file(assets / "templates" / "builtin.toml", root / "assets" / "templates" / "builtin.toml");
  const auto scriptDir = root / "assets" / "templates" / "starship";
  for (const auto* script : {"apply.sh", "undo.sh"}) {
    std::filesystem::copy_file(assets / "templates" / "starship" / script, scriptDir / script);
  }
  writeFile(scriptDir / "starship.toml", "[palettes.noctalia]\nblue = '#112233'\n");

  ::setenv("NOCTALIA_CONFIG_HOME", (root / "config").c_str(), 1);
  ::setenv("NOCTALIA_STATE_HOME", (root / "state").c_str(), 1);
  ::setenv("NOCTALIA_DATA_HOME", (root / "data").c_str(), 1);
  ::setenv("NOCTALIA_ASSETS_DIR", (root / "assets").c_str(), 1);
  ::setenv("XDG_CONFIG_HOME", (root / "config").c_str(), 1);
  ::setenv("XDG_CACHE_HOME", (root / "cache").c_str(), 1);

  const auto previousDirectory = std::filesystem::current_path();
  std::filesystem::current_path(root);
  const auto target = root / "Starship ' $(touch injected) `touch injected2`.toml";
  const auto targetContents = root / "target.toml";
  const auto stale = root / "stale.toml";
  const auto defaultConfig = root / "config" / "starship.toml";
  const std::string original = "add_newline = false\n[character]\nsuccess_symbol = '[>](blue)'\n";
  writeFile(targetContents, original);
  std::filesystem::create_symlink(targetContents, target);
  writeFile(stale, original);
  writeFile(defaultConfig, original);
  ::setenv("STARSHIP_CONFIG", stale.c_str(), 1);

  writeConfig(root, true, target.string());
  {
    ConfigService config;
    apply(config);
    TEST_CHECK(readFile(target).contains("palette = \"noctalia\""));
    TEST_CHECK(readFile(target).contains("success_symbol"));
    TEST_CHECK(std::filesystem::is_symlink(target));
    TEST_CHECK(config.stateString("theme_templates", "starship_config") == target.string());
  }
  TEST_CHECK(readFile(stale) == original);
  TEST_CHECK(readFile(defaultConfig) == original);
  TEST_CHECK(!std::filesystem::exists(root / "injected"));
  TEST_CHECK(!std::filesystem::exists(root / "injected2"));

  // Removing the explicit setting while disabling must retain the target across
  // a restart. A failed undo must retain that ownership for the next attempt.
  const std::string undoScript = readFile(scriptDir / "undo.sh");
  writeFile(scriptDir / "undo.sh", "exit 1\n");
  writeConfig(root, false);
  {
    ConfigService config;
    apply(config);
    TEST_CHECK(config.stateString("theme_templates", "starship_config") == target.string());
    TEST_CHECK(config.stateString("theme_templates", "applied_builtin_ids") == "starship");
    TEST_CHECK(readFile(target).contains("palette = \"noctalia\""));
  }
  writeFile(scriptDir / "undo.sh", undoScript);
  {
    ConfigService config;
    apply(config);
    TEST_CHECK(config.stateString("theme_templates", "starship_config") == "");
    TEST_CHECK(config.stateString("theme_templates", "applied_builtin_ids") == "");
  }
  TEST_CHECK(!readFile(target).contains("noctalia"));
  TEST_CHECK(readFile(target).starts_with(original));
  TEST_CHECK(std::filesystem::is_symlink(target));
  TEST_CHECK(readFile(stale) == original);
  TEST_CHECK(readFile(defaultConfig) == original);
  TEST_CHECK(!std::filesystem::exists(root / "injected"));
  TEST_CHECK(!std::filesystem::exists(root / "injected2"));

  // An empty setting while still enabled restores inherited STARSHIP_CONFIG
  // selection and clears the old explicit undo target.
  writeConfig(root, true, target.string());
  {
    ConfigService config;
    apply(config);
    writeConfig(root, true);
    config.forceReload();
    apply(config);
    TEST_CHECK(config.stateString("theme_templates", "starship_config") == "");
    TEST_CHECK(readFile(stale).contains("palette = \"noctalia\""));
    writeConfig(root, false);
    config.forceReload();
    apply(config);
    TEST_CHECK(!readFile(stale).contains("noctalia"));
    TEST_CHECK(readFile(target).contains("palette = \"noctalia\""));
  }
  TEST_CHECK(readFile(defaultConfig) == original);

  std::filesystem::current_path(previousDirectory);
  std::filesystem::remove_all(root);
}
