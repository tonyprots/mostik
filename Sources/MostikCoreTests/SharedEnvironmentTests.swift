import Foundation
import MostikCore

/// Списки окружения и изоляции приложения против общего эталона `docs/engine-environment.json`.
/// Python сверяет свою половину в `engine/tests/test_shared_environment.py`.
func runSharedEnvironmentTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("docs/engine-environment.json")
    guard let data = try? Data(contentsOf: url),
          let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "эталон окружения не читается: \(url.path)")
        return
    }
    func list(_ key: String) -> [String] { spec[key] as? [String] ?? ["<нет \(key)>"] }
    func nested(_ key: String) -> [String] { (spec[key] as? [String: Any])?["keys"] as? [String] ?? ["<нет \(key)>"] }

    equal(EngineEnvironment.offline, spec["offline"] as? [String: String] ?? [:], "офлайн-флаги")
    equal(EngineEnvironment.debugOnlyOverrides, list("dev_only_overrides"), "переопределения для разработки")
    equal(EngineEnvironment.unsafePrefixes, list("unsafe_prefixes"), "опасные префиксы")
    equal(EngineEnvironment.releaseDropPrefixes, list("release_drop_prefixes"), "префиксы, снимаемые в выпуске")
    equal(EngineEnvironment.releaseDrop, list("release_drop"), "переменные, снимаемые в выпуске")
    equal(EngineEnvironment.toolchain, list("toolchain"), "переменные toolchain")
    equal(EngineEnvironment.addressOverrides, nested("app_only_address_overrides"), "адреса — только командой")

    equal(ToolEnvironment.defaultPath, spec["system_path"] as? String ?? "", "системный PATH")
    equal(ToolEnvironment.allowed, Set(list("base_keys")), "белый список утилит")
    equal(EngineEnvironment.engineKeys, Set(list("base_keys") + list("engine_keys")), "белый список движка")
    equal(Set(EngineEnvironment.enginePrefixes), Set(list("base_prefixes") + list("engine_prefixes")), "префиксы движка")
    for key in nested("engine_set_child_keys") {
        check(!EngineEnvironment.engineKeys.contains(key), "\(key) ставит сам движок, приложение его не передаёт")
    }
    equal(SafeGit.hardening, list("safe_git"), "защита git")
}
