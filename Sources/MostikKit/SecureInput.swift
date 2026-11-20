import Carbon.HIToolbox
import Darwin
import IOKit
import MostikCore

/// Защищённый ввод (поле пароля Cocoa или браузера, «Защищённый ввод с клавиатуры» терминала): П10 р4 Р4-4л.
public enum SecureInput {
    public static var enabled: Bool { IsSecureEventInputEnabled() }

    /// Кто последним включил защищённый ввод: `kCGSSessionSecureInputPID` сессии текущего пользователя в
    /// `IOConsoleUsers`. Флаг общий на всю систему, и застрявший `loginwindow` после разблокировки экрана
    /// выглядит для Mostik как «поле пароля» в любом приложении — без держателя в логе это не отличить.
    /// Ключ остаётся и после выключения флага, поэтому смотреть его имеет смысл только при `enabled`.
    public static var holder: SecureInputHolder? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let raw = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0),
              let users = raw.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uid = getuid()
        guard let user = users.first(where: { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }),
              let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let name = proc_pidpath(pid, &path, UInt32(path.count)) > 0
            ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : nil
        return SecureInputHolder(pid: pid, name: name)
    }
}
