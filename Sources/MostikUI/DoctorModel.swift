import Foundation
import SwiftUI
import MostikCore

/// Состояние «Проверки» (R7). Пишет `UpkeepController`, читает группа в Настройках.
@MainActor
public final class DoctorModel: ObservableObject {
    @Published public var checks: [DoctorCheck] = []
    @Published public var checkedAt: Date?
    @Published public var running = false

    public init() {}

    public var worst: DoctorCheck.Status { Doctor.worst(checks) }
    public var problems: [DoctorCheck] { checks.filter { $0.status >= .warning } }

    // Намерения
    public var onRun: () -> Void = {}
    public var onFix: (DoctorCheck.Fix) -> Void = { _ in }
    /// Папка журналов в Finder — чтобы прислать их без Терминала.
    public var onRevealLogs: () -> Void = {}

    public static func title(_ kind: DoctorCheck.Kind) -> String {
        switch kind {
        case .microphone: return L("Микрофон", "Microphone")
        case .accessibility: return L("Универсальный доступ", "Accessibility")
        case .postEvents: return L("Право вставлять текст", "Permission to paste")
        case .systemAudio: return L("Звук собеседников", "Other side’s audio")
        case .hotkey: return L("Клавиша записи", "Record key")
        case .engine: return L("Движок", "Engine")
        case .models: return L("Модели", "Models")
        case .diarization: return L("Разделение по голосам", "Speaker separation")
        case .disk: return L("Место на диске", "Disk space")
        case .llm: return L("Модель для причёсывания", "Polishing model")
        case .logs: return L("Журнал и сбои", "Log and crashes")
        case .loginItem: return L("Запуск при входе", "Open at login")
        }
    }

    public static func fixTitle(_ fix: DoctorCheck.Fix) -> String {
        switch fix {
        case .requestMicrophone: return L("Разрешить", "Allow")
        case .relaunch: return L("Перезапустить", "Relaunch")
        case .restartEngine: return L("Перезапустить", "Restart")
        case .openPolish: return L("К причёсыванию", "Polish settings")
        case .requestAccessibility: return L("Исправить", "Fix")
        case .openMicrophone, .openSystemAudio, .openKeyboard, .openStorage, .openLoginItems: return L("Открыть настройки", "Open Settings")
        case .showLogs: return L("Показать в Finder", "Show in Finder")
        case .downloadModels, .downloadDiarization: return L("Скачать", "Download")
        }
    }
}
