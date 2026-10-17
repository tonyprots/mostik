import Foundation
import IOKit.ps
import MostikCore

public struct PowerState: Equatable, Sendable {
    /// "nominal" | "fair" | "serious" | "critical"
    public var thermal: String
    public var onBattery: Bool
    public var lowPower: Bool
    /// Заряд в процентах; nil — батареи нет.
    public var batteryPercent: Int?

    /// Тёплый микрофон гасим на батарее ниже 20 %.
    public var batteryLow: Bool { onBattery && (batteryPercent ?? 100) < 20 }

    /// Поля команды `power` протокола движка.
    public var commandFields: [String: JSONValue] {
        ["thermal": .string(thermal), "on_battery": .bool(onBattery), "low_power": .bool(lowPower),
         "battery": batteryPercent.map { .number(Double($0)) } ?? .null]
    }
}

/// Следит за нагревом, энергосбережением и питанием; зовёт `onChange` только при изменении.
public final class PowerMonitor: @unchecked Sendable {
    private let onChange: (PowerState) -> Void
    private var observers: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?
    public private(set) var current: PowerState

    public init(onChange: @escaping (PowerState) -> Void) {
        self.onChange = onChange
        self.current = PowerMonitor.read()
    }

    public static func read() -> PowerState {
        let info = ProcessInfo.processInfo
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "nominal"
        }
        var onBattery = false
        var percent: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
                onBattery = type == kIOPSBatteryPowerValue
            }
            if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
                for source in list {
                    guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                          let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                          let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                    percent = cur * 100 / max
                }
            }
        }
        return PowerState(thermal: thermal, onBattery: onBattery, lowPower: info.isLowPowerModeEnabled,
                          batteryPercent: percent)
    }

    public func start() {
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
    }

    private func refresh() {
        let next = PowerMonitor.read()
        // Проценты дёргаются часто — событие только при смене значимых полей.
        let significant = next.thermal != current.thermal || next.onBattery != current.onBattery
            || next.lowPower != current.lowPower || next.batteryLow != current.batteryLow
        current = next
        if significant { onChange(next) }
    }

    deinit { stop() }
}
