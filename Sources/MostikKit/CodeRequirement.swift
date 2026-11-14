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

    /// Отпечаток кода (cdhash) запущенного процесса — по коду в памяти, а не по пути, откуда он
    /// запущен. nil — подписи нет: сверять не с чем.
    public static func runningCodeHash() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return hash(of: staticCode)
    }

    /// Отпечаток кода бандла на диске.
    public static func codeHash(at url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return hash(of: code)
    }

    /// Бандл на диске цел (подпись сходится с исполняемым файлом и ресурсами) и это тот же код.
    /// Требование подписи здесь не годится: у ad-hoc сборки оно — одно имя `app.mostik.mac`
    /// (`scripts/sign-app.sh`), ему отвечает любой бандл, подписанный тем же именем.
    public static func isIntact(_ url: URL, sameAs hash: Data) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        return self.hash(of: code) == hash
    }

    private static func hash(of code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique
    }
}
