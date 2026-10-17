import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MostikCore

/// Входы звука для строки «Микрофон» в Настройках (R3b): список устройств с входными каналами,
/// системный вход и привязка своего `AVAudioEngine` к выбранному устройству.
/// Только чтение системных свойств: вход по умолчанию в macOS Mostik не меняет (`MicChoice`).
public enum AudioInputs {
    /// Устройства, у которых есть входные потоки, по имени.
    public static func list() -> [MicChoice.Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let name = string(kAudioObjectPropertyName, of: id),
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
            return MicChoice.Device(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Системный вход по умолчанию; nil — входа нет. Только чтение.
    public static func systemDefaultID() -> UInt32? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// С какого устройства писать при выборе `uid` (пусто — как в системе).
    public static func resolve(uid: String) -> MicChoice.Resolution {
        MicChoice.resolve(chosenUID: uid, devices: uid.isEmpty ? [] : list(), systemDefault: systemDefaultID())
    }

    /// Привязать вход своего `AVAudioEngine` к устройству — до чтения формата и установки тапа.
    /// Меняет только этот аудиоюнит, не систему. false — устройство не принято.
    @discardableResult
    public static func bind(_ input: AVAudioInputNode, to device: UInt32) -> Bool {
        guard let unit = input.audioUnit else { return false }
        var id = AudioDeviceID(device)
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// Тип подключения устройства — для тёплого микрофона (`WarmMicPolicy.suitsWarm`).
    public static func transport(of device: UInt32) -> WarmMicPolicy.Transport {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return .unknown }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypePCI: return .pci
        case kAudioDeviceTransportTypeFireWire: return .fireWire
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .unknown
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
        return text
    }
}
