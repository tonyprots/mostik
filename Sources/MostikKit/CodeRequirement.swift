import Foundation
import Security

/// Требование подписи (designated requirement) бандла на диске — то, по чему macOS узнаёт приложение
/// в разрешениях. Только Foundation и Security: файл собирается и в пробу цепочки обновления
/// (`scripts/update-e2e.sh`), где нет остальных модулей.
public enum CodeRequirement {
    /// `identifier "app.mostik.mac" and certificate leaf = H"…"` или nil, если подписи нет или она не читается.
    public static func designated(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
