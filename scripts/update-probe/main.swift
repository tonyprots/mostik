// Проба цепочки обновления для scripts/update-e2e.sh: настоящий Sparkle и настоящий SparkleUpdateGuard
// обновляют копию Mostik.app во временной папке. Сам Mostik не запускается: проба — отдельный процесс
// со своим окном-невидимкой, без перезапуска после установки.
//
//   update-probe <путь к Mostik.app>   → печатает RESULT: installed | error <домен> <код> <текст> | none
import AppKit
import ObjectiveC
import Sparkle

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 2 else { print("usage: update-probe <Mostik.app>"); exit(64) }
let hostURL = URL(fileURLWithPath: args[1])
guard let host = Bundle(url: hostURL) else { print("RESULT: error probe 0 нет бандла"); exit(1) }

func finish(_ line: String) -> Never {
    print("RESULT: \(line)")
    exit(0)
}

final class ProbeDelegate: SparkleUpdateGuard {
    @objc func updaterShouldRelaunchApplication(_ updater: NSObject) -> Bool { false }
    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: NSObject, didFinishLoadingAppcast appcast: NSObject) {
        print("appcast загружен")
    }
}
// Тот же объект, что получает Sparkle в Mostik; протокол добавляем в рантайме — у Mostik так же (без линковки).
class_addProtocol(ProbeDelegate.self, SPUUpdaterDelegate.self)

final class AutoDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("найдено обновление \(appcastItem.displayVersionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finish("none \((error as NSError).localizedDescription)")
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " | \($0.domain) \($0.code) \($0.localizedDescription)" } ?? ""
        let hint = (e.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String).map { " | \($0)" } ?? ""
        finish("error \(e.domain) \(e.code) \(e.localizedDescription)\(hint)\(under)")
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { print("скачивание") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { print("распаковка") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("готово к установке")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        print("установка (приложение завершено: \(applicationTerminated))")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        finish("installed relaunched=\(relaunched)")
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() { print("окно обновления закрыто") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let delegate = ProbeDelegate(hostBundleURL: hostURL, russian: true, onBlocked: { title, body in
    print("onBlocked: \(title) — \(body)")
})
let driver = AutoDriver()
let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver,
                         delegate: (delegate as AnyObject) as? SPUUpdaterDelegate)
do { try updater.start() } catch {
    finish("error start \((error as NSError).code) \(error.localizedDescription)")
}
updater.checkForUpdates()
// Установщик Sparkle ждёт завершения процесса-хозяина: после «установка» выходим сами и даём ему доработать.
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { finish("timeout") }
app.run()
