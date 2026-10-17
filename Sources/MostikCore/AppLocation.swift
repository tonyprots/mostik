import Foundation

/// Откуда запущен Mostik. Из окна `.dmg` и из «транслоцированной» копии
/// (Gatekeeper запускает скачанное приложение из случайной папки только для чтения) разрешения
/// macOS привязываются к временному пути, обновления не ставятся, а после извлечения диска приложение
/// пропадает. Предлагаем перенести в «Программы».
public enum AppLocation {
    public enum Problem: Equatable, Sendable {
        /// Запуск прямо с подключённого образа или другого тома.
        case diskImage
        /// Gatekeeper App Translocation: путь вида `/private/var/folders/…/AppTranslocation/…`.
        case translocated
    }

    /// Только для собранного `.app`: отладочный бинарник из `.build` не трогаем.
    public static func problem(bundlePath: String) -> Problem? {
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return nil }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        return nil
    }

    /// Куда переносить: системные «Программы». Пользовательскую `~/Applications` не берём —
    /// у человека её обычно нет, а Finder показывает «Программы» в боковой панели.
    public static func destination(bundleName: String) -> String { "/Applications/" + bundleName }

    public static func title(russian: Bool) -> String {
        russian ? "Перенести Mostik в «Программы»?" : "Move Mostik to Applications?"
    }

    public static func message(_ problem: Problem, russian: Bool) -> String {
        switch problem {
        case .diskImage:
            return russian
                ? "Mostik запущен прямо с диска установки. Так разрешения macOS и обновления не сохранятся, а после извлечения диска приложение пропадёт."
                : "Mostik is running straight from the install disk. Permissions and updates won’t stick, and the app goes away when the disk is ejected."
        case .translocated:
            return russian
                ? "macOS запустила Mostik из временной копии, потому что приложение не в «Программах». Разрешения, выданные этой копии, после перезапуска могут пропасть."
                : "macOS launched Mostik from a temporary copy because the app isn’t in Applications. Permissions given to this copy may be lost after a relaunch."
        }
    }

    /// Перенести не вышло (нет прав на «Программы», копия занята): что сделать руками.
    public static func manualHint(russian: Bool) -> String {
        russian
            ? "Не получилось перенести самому. Перетащите Mostik в папку «Программы» в Finder и откройте его оттуда."
            : "Couldn’t move it automatically. Drag Mostik into the Applications folder in Finder and open it from there."
    }
}
