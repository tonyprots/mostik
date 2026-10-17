import SwiftUI
import MostikCore

/// Снимки «Проверки» (R7) и группы «Мышь, гарнитура, звук» (H4–H6) на демо-данных.
extension Snapshots {
    /// Всё в порядке — так «Проверка» выглядит в общем снимке Настроек.
    static func doctorAllGood() -> [DoctorCheck] {
        var f = DoctorFacts()
        f.microphone = .authorized; f.accessibility = true; f.postEvents = true; f.systemAudio = true
        f.engine = .ready; f.missingModels = []; f.diarizationAvailable = true; f.freeBytes = 182_000_000_000
        f.llmBackend = "mlx"; f.llmAvailable = true
        return Doctor.evaluate(f, russian: L10n.isRussian)
    }

    /// Типичный плохой день: доступ выдан на ходу, fn под раскладкой, мало места, модель не в кэше.
    static func doctorProblems() -> [DoctorCheck] {
        var f = DoctorFacts()
        f.microphone = .authorized; f.accessibility = true; f.postEvents = false; f.systemAudio = false
        f.holdKey = "fn"; f.fnUsage = 1
        f.engine = .ready; f.missingModels = ["whisper-turbo-mlx"]; f.diarizationAvailable = false; f.freeBytes = 6_400_000_000
        f.llmBackend = "claude"; f.llmAvailable = false
        return Doctor.evaluate(f, russian: L10n.isRussian)
    }

    @MainActor
    static func renderDoctor(to dir: URL) {
        let checkedAt = Calendar.current.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
        for dark in [false, true] {
            let model = demoModel()
            model.doctor.checks = doctorProblems()
            model.doctor.checkedAt = checkedAt
            write(settingsStage(DoctorSection(doctor: model.doctor)), "settings-doctor" + (dark ? "-dark" : ""), dir,
                  width: 688, dark: dark)
        }
        let ok = demoModel()
        ok.doctor.checks = doctorAllGood()
        ok.doctor.checkedAt = checkedAt
        write(settingsStage(DoctorSection(doctor: ok.doctor)), "settings-doctor-ok", dir, width: 688)

        let never = demoModel()
        never.doctor.checks = []
        write(settingsStage(DoctorSection(doctor: never.doctor)), "settings-doctor-empty", dir, width: 688)

        // Включены мышь «назад», гарнитура и приглушение.
        for dark in [false, true] {
            let triggers = demoModel()
            triggers.settingsPane = .general
            triggers.settings.mouseTrigger = "back"
            triggers.settings.headsetTrigger = true
            triggers.settings.muteWhileRecording = true
            write(SettingsWindowView(model: triggers), "main-settings-triggers" + (dark ? "-dark" : ""), dir,
                  width: 900, height: 922, dark: dark)
        }
    }

    /// Группа Настроек на фоне окна, с теми же полями, что во вкладке.
    @MainActor
    private static func settingsStage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
