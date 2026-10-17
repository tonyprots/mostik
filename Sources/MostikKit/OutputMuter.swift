import AudioToolbox
import CoreAudio
import Foundation

/// Приглушение системного звука на время диктовки (H6).
///
/// Перед изменением прежнее состояние пишется в UserDefaults, после восстановления —
/// стирается. Упало приложение посреди записи — `restoreLeftover()` при следующем
/// запуске вернёт звук. Трогаем только то, что меняли сами: звук уже был выключен —
/// ничего не делаем и потом не включаем.
@MainActor
public final class OutputMuter {
    private static let key = "mostik.outputMuteSaved"

    /// Что поменяли: устройство и способ.
    private struct Saved: Codable {
        var uid: String
        /// "mute" — флаг mute; "volume" — громкость в ноль, `volume` — прежняя.
        var mode: String
        var volume: Float?
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isMuted: Bool { defaults.data(forKey: Self.key) != nil }

    /// Приглушить устройство вывода по умолчанию. Повторный вызов ничего не делает.
    public func mute() {
        guard !isMuted, let device = Self.defaultOutput(), let uid = Self.uid(of: device) else { return }
        if Self.isSettable(device, kAudioDevicePropertyMute) {
            if Self.readUInt32(device, kAudioDevicePropertyMute) == 1 { return }
            save(Saved(uid: uid, mode: "mute"))
            Self.writeUInt32(device, kAudioDevicePropertyMute, 1)
        } else if Self.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                  let volume = Self.readFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
            if volume == 0 { return }
            save(Saved(uid: uid, mode: "volume", volume: volume))
            Self.writeFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 0)
        }
    }

    /// Вернуть, как было. Устройство отключили — запись всё равно стираем: возвращать некуда.
    public func restore() {
        guard let data = defaults.data(forKey: Self.key) else { return }
        defer { defaults.removeObject(forKey: Self.key) }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let device = Self.device(uid: saved.uid) else { return }
        switch saved.mode {
        case "mute":
            Self.writeUInt32(device, kAudioDevicePropertyMute, 0)
        default:
            if let volume = saved.volume {
                Self.writeFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, volume)
            }
        }
    }

    /// При запуске: прошлый процесс не успел вернуть звук.
    public func restoreLeftover() { restore() }

    private func save(_ saved: Saved) {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { Self.uid(of: $0) == uid }
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    private static func readUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) {
        var addr = address(selector)
        var v = value
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    private static func readFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float? {
        var addr = address(selector)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Float) {
        var addr = address(selector)
        var v = Float32(value)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
