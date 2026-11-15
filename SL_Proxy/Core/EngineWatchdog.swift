import Foundation
import UserNotifications

/// Dead-man's switch for the loopback proxy.
///
/// The cellular profile points the APN at `127.0.0.1:<port>`. If iOS kills SL_Proxy (memory
/// pressure, a force-quit, a crash) nothing listens any more and mobile data stops until the app is
/// reopened or the profile is removed. An app cannot run code after it has been killed, so the
/// watchdog works the other way round: while the process is alive it keeps ONE local notification
/// scheduled `alertDelay` seconds ahead and replaces it every `refreshInterval`. As long as the app
/// lives the notification never fires. When the app dies the refreshing stops and the notification
/// goes off, telling the user to reopen SL_Proxy.
///
/// `start()` / `stop()` are driven by `TunnelController.syncKeepAlive()`, i.e. exactly while the
/// core or the passthrough holds the port. `stop()` also clears a delivered alert.
@MainActor
final class EngineWatchdog {
    static let identifier = "com.slproxy.watchdog.engine-stopped"
    /// How often the pending alert is pushed back while the process is alive.
    static let refreshInterval: Duration = .seconds(20)
    /// Seconds from the last refresh to the alert. Must stay well above `refreshInterval`.
    static let alertDelay: TimeInterval = 75

    private var task: Task<Void, Never>?

    var isArmed: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task {
            await Self.requestAuthorizationIfNeeded()
            while !Task.isCancelled {
                Self.arm()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    // MARK: - Notifications

    /// Asks once; a denied permission simply means the alert never shows.
    nonisolated private static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Schedules (or replaces: same identifier) the alert `alertDelay` seconds from now.
    nonisolated private static func arm() {
        let content = UNMutableNotificationContent()
        content.title = "SL_Proxy stopped"
        content.body = "The local proxy is no longer running. If you use the cellular profile, mobile data will not work until you reopen SL_Proxy."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: alertDelay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
