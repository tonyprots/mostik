import Foundation

/// Выбор микрофона в Настройках (R3b): только для захвата Mostik. Вход по умолчанию в macOS
/// Mostik не меняет никогда — от него зависят Zoom, Телемост и всё остальное.
///
/// Выбор хранится по UID устройства (`MostikSettings.micDeviceUID`): числовой ID Core Audio
/// меняется при переподключении. Пустой UID — «Как в системе»: пишем с системного входа и
/// идём за ним при смене. Выбранное устройство закреплено: смена системного входа его не
/// переключает. Выбранного нет (AirPods в футляре) — пишем с системного входа и говорим об этом.
public enum MicChoice {
    public struct Device: Equatable, Sendable {
        public let id: UInt32
        public let uid: String
        public let name: String
        public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
    }

    public struct Resolution: Equatable, Sendable {
        /// С какого устройства писать; nil — входа нет вовсе.
        public let device: UInt32?
        /// Пишем с выбранного устройства: смена системного входа захват не переключает.
        public let pinned: Bool
        /// Устройство выбрано, но не подключено — пишем с системного входа.
        public let chosenMissing: Bool
        public init(device: UInt32?, pinned: Bool, chosenMissing: Bool) {
            self.device = device; self.pinned = pinned; self.chosenMissing = chosenMissing
        }
    }

    public static func resolve(chosenUID: String, devices: [Device], systemDefault: UInt32?) -> Resolution {
        guard !chosenUID.isEmpty else { return Resolution(device: systemDefault, pinned: false, chosenMissing: false) }
        if let chosen = devices.first(where: { $0.uid == chosenUID }) {
            return Resolution(device: chosen.id, pinned: true, chosenMissing: false)
        }
        return Resolution(device: systemDefault, pinned: false, chosenMissing: true)
    }

    /// Подсказка строки «Вход» в Настройках.
    public static func hint(chosenUID: String, chosenName: String, devices: [Device]) -> String {
        let r = resolve(chosenUID: chosenUID, devices: devices, systemDefault: nil)
        if r.chosenMissing {
            let name = chosenName.isEmpty ? UIText.pick("Выбранный микрофон", "The chosen microphone") : "«\(chosenName)»"
            return UIText.pick("\(name) не подключён — пишем с системного входа.",
                               "\(name) isn’t connected, so Mostik records from the system input.")
        }
        return UIText.pick("Выбор действует только в Mostik: системный микрофон не меняется.",
                           "Applies to Mostik only. Other apps keep the system mic.")
    }
}
