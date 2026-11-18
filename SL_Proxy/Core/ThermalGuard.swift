import Foundation
import UserNotifications

/// Thermal awareness for the always-on loopback engine.
///
/// The app keeps sing-box, a silent audio session and a few pollers running for as long as the
/// proxy is connected, and on a phone that also routes all cellular traffic through it the
/// sustained load adds up to heat. iOS reports it through `ProcessInfo.thermalState`; this file
/// reads that state and does two things with it:
///  - `ThermalGuard.pollScale` stretches the background pollers (profile verifier, connected
///    clients) 3x at `.serious` and 6x at `.critical`, which is the only load the app can shed
///    without breaking the proxy;
///  - `ThermalMonitor` writes the transitions to the engine log and, once per cooldown, posts a
///    notification at `.serious` / `.critical` so the user can disconnect and let the phone cool.
enum ThermalGuard {
    /// Multiplier for poll intervals; 1 when the device is cool.
    static var pollScale: Int64 {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return 1
        case .serious: return 3
        case .critical: return 6
        @unknown default: return 1
        }
    }

    static var isHot: Bool { pollScale > 1 }

    static func title(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

@MainActor
final class ThermalMonitor {
    private static let identifier = "com.slproxy.thermal.warning"
    /// Minimum time between two heat notifications.
    private static let cooldown: TimeInterval = 15 * 60

    private var observer: NSObjectProtocol?
    private var lastNotified: Date?

    func start(log: @escaping (String) -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleChange(log: log) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func handleChange(log: (String) -> Void) {
        let state = ProcessInfo.processInfo.thermalState
        log("Thermal state: \(ThermalGuard.title(for: state))"
            + (ThermalGuard.isHot ? "; background polling slowed x\(ThermalGuard.pollScale)" : ""))
        guard ThermalGuard.isHot else { return }
        if let lastNotified, Date().timeIntervalSince(lastNotified) < Self.cooldown { return }
        lastNotified = Date()

        let content = UNMutableNotificationContent()
        content.title = "iPhone is running hot"
        content.body = state == .critical
            ? "Thermal state is critical. Disconnect SL_Proxy and let the phone cool down to avoid a forced shutdown."
            : "SL_Proxy slowed its background checks. If the phone keeps heating up, disconnect for a while."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
