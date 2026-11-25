import Foundation
import UIKit

/// Phase 4: device telemetry for the thermal/battery guardrails and the Launch &
/// Diagnostics sheet.
///
///  • Thermal: `ProcessInfo.thermalStateDidChangeNotification` (+ initial value).
///  • Battery: `UIDevice` battery monitoring (level + charging).
///  • Storage: `volumeAvailableCapacityForImportantUsage` on the app container, polled
///    every 15 s (cheap; the system caches it). Requires the DiskSpace reason in
///    PrivacyInfo.xcprivacy (E174.1), which is included.
///
/// Everything is delivered on the main actor.
@MainActor
final class SystemMonitor {

    var onThermalChange: ((ProcessInfo.ThermalState) -> Void)?
    var onBatteryChange: ((Float?, Bool) -> Void)?
    var onStorageChange: ((Int64?) -> Void)?

    private var tasks: [Task<Void, Never>] = []

    func start() {
        stop()
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Initial values.
        onThermalChange?(ProcessInfo.processInfo.thermalState)
        reportBattery()
        reportStorage()

        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                self?.onThermalChange?(ProcessInfo.processInfo.thermalState)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.batteryLevelDidChangeNotification) {
                self?.reportBattery()
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.batteryStateDidChangeNotification) {
                self?.reportBattery()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.reportStorage()
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func reportBattery() {
        let device = UIDevice.current
        let level: Float? = device.batteryLevel < 0 ? nil : device.batteryLevel   // -1 = unknown (Simulator)
        let charging = device.batteryState == .charging || device.batteryState == .full
        onBatteryChange?(level, charging)
    }

    private func reportStorage() {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        onStorageChange?(values?.volumeAvailableCapacityForImportantUsage)
    }

    /// Recording minutes left at the given total bitrate (both cameras in dual mode).
    static func minutesLeft(bytes: Int64?, totalBitsPerSecond: Int) -> Int? {
        guard let bytes, totalBitsPerSecond > 0 else { return nil }
        // Keep 1 GB in reserve so iOS never has to purge mid-take.
        let usable = max(0, bytes - 1_000_000_000)
        return Int(Double(usable) * 8 / Double(totalBitsPerSecond) / 60)
    }
}
