import Combine
import Foundation
import UserNotifications

/// Counts the bytes the proxy moves while the device is on cellular and enforces the daily and
/// monthly caps from Settings > Advanced & Pro > Data Budget.
///
/// `TrafficMonitor` publishes one `TrafficDelta` per second; every delta that arrives while
/// `NetworkPathObserver.isCellular` is true is added to the current day and month, which are
/// persisted in the shared defaults and roll over on their own. Crossing 90% of a cap posts a
/// local notification once per period; crossing 100% posts another and calls `onLimitReached`
/// (wired by `TunnelController` to disconnect the engine) on every further cellular sample, so
/// reconnecting on cellular while over the cap is stopped again immediately.
@MainActor
final class DataBudgetTracker: ObservableObject {
    enum Period: String, Codable, CaseIterable {
        case daily, monthly

        var title: String { self == .daily ? "Daily" : "Monthly" }
        var noun: String { self == .daily ? "today" : "this month" }
    }

    struct Usage: Codable, Equatable {
        var dayKey = ""
        var dayBytes: Int64 = 0
        var dayWarned = false
        var dayExceeded = false
        var monthKey = ""
        var monthBytes: Int64 = 0
        var monthWarned = false
        var monthExceeded = false
    }

    @Published private(set) var usage = Usage()
    /// nil until the authorization status has been read.
    @Published private(set) var notificationsAuthorized: Bool?
    /// Last threshold message, for the settings screen.
    @Published private(set) var lastEvent: String?

    /// Called with the period and cap whenever a cellular sample lands at or above a cap.
    var onLimitReached: ((Period, Int64) -> Void)?

    private let settings: SettingsStore
    private let path: NetworkPathObserver
    private let presenter = ForegroundNotificationPresenter()
    private var subscription: AnyCancellable?
    private let storageKey = "cellular-data-usage"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    init(settings: SettingsStore, path: NetworkPathObserver) {
        self.settings = settings
        self.path = path
        if let data = AppGroup.sharedDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(Usage.self, from: data) {
            usage = stored
        }
        rollover(Date())
        UNUserNotificationCenter.current().delegate = presenter
        Task { await refreshAuthorization() }
    }

    // MARK: - Wiring

    /// Subscribes to the monitor's per-second samples; call once.
    func attach(to traffic: TrafficMonitor) {
        subscription = traffic.samples
            .receive(on: RunLoop.main)
            .sink { [weak self] delta in
                self?.record(delta)
            }
    }

    // MARK: - Queries

    var dailyCap: Int64? { settings.value.dailyCapBytes }
    var monthlyCap: Int64? { settings.value.monthlyCapBytes }

    /// 0...1 share of the daily cap used, nil without a cap.
    var dailyProgress: Double? { progress(usage.dayBytes, cap: dailyCap) }
    var monthlyProgress: Double? { progress(usage.monthBytes, cap: monthlyCap) }

    /// The period whose cap is currently reached, daily first; nil while budgets are off or under.
    var exceededPeriod: Period? {
        guard settings.value.dataBudgetEnabled else { return nil }
        if let cap = dailyCap, usage.dayBytes >= cap { return .daily }
        if let cap = monthlyCap, usage.monthBytes >= cap { return .monthly }
        return nil
    }

    func bytes(for period: Period) -> Int64 {
        period == .daily ? usage.dayBytes : usage.monthBytes
    }

    func cap(for period: Period) -> Int64? {
        period == .daily ? dailyCap : monthlyCap
    }

    /// Re-checks the period keys (call when a screen appears so a new day shows zero).
    func refresh() {
        rollover(Date())
    }

    func resetUsage() {
        usage = Usage()
        rollover(Date())
        lastEvent = nil
        persist()
    }

    // MARK: - Notifications

    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAuthorized = status == .authorized || status == .provisional || status == .ephemeral
    }

    func requestAuthorization() async {
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        notificationsAuthorized = granted ?? false
    }

    // MARK: - Private

    private func record(_ delta: TrafficDelta) {
        guard path.isCellular else { return }
        let bytes = delta.down + delta.up
        guard bytes > 0 else { return }
        let now = Date()
        rollover(now)
        usage.dayBytes += bytes
        usage.monthBytes += bytes
        evaluate()
        persist()
    }

    private func rollover(_ now: Date) {
        let day = Self.dayFormatter.string(from: now)
        let month = Self.monthFormatter.string(from: now)
        var changed = false
        if usage.dayKey != day {
            usage.dayKey = day
            usage.dayBytes = 0
            usage.dayWarned = false
            usage.dayExceeded = false
            changed = true
        }
        if usage.monthKey != month {
            usage.monthKey = month
            usage.monthBytes = 0
            usage.monthWarned = false
            usage.monthExceeded = false
            changed = true
        }
        if changed { persist() }
    }

    private func evaluate() {
        guard settings.value.dataBudgetEnabled else { return }
        // Swift forbids two inout references to sub-properties of the same computed
        // property in a single call (aliasing). Copy the flags out, pass locals, write back.
        var dayWarned = usage.dayWarned
        var dayExceeded = usage.dayExceeded
        check(.daily, used: usage.dayBytes, cap: dailyCap, warned: &dayWarned, exceeded: &dayExceeded)
        usage.dayWarned = dayWarned
        usage.dayExceeded = dayExceeded

        var monthWarned = usage.monthWarned
        var monthExceeded = usage.monthExceeded
        check(.monthly, used: usage.monthBytes, cap: monthlyCap, warned: &monthWarned, exceeded: &monthExceeded)
        usage.monthWarned = monthWarned
        usage.monthExceeded = monthExceeded
    }

    private func check(_ period: Period, used: Int64, cap: Int64?, warned: inout Bool, exceeded: inout Bool) {
        guard let cap, cap > 0 else { return }
        if used >= cap {
            if !exceeded {
                exceeded = true
                warned = true
                let text = "\(period.title) cellular cap reached: \(TrafficMonitor.bytes(used)) of \(TrafficMonitor.bytes(cap)) used \(period.noun)."
                lastEvent = text
                notify(
                    title: "\(period.title) cellular data cap reached",
                    body: settings.value.budgetAutoDisconnect
                        ? "\(TrafficMonitor.bytes(cap)) used \(period.noun). SL_Proxy disconnected to avoid overages."
                        : "\(TrafficMonitor.bytes(cap)) used \(period.noun)."
                )
            }
            onLimitReached?(period, cap)
        } else if !warned, used * 10 >= cap * 9 {
            warned = true
            let text = "90% of the \(period.title.lowercased()) cellular cap used: \(TrafficMonitor.bytes(used)) of \(TrafficMonitor.bytes(cap))."
            lastEvent = text
            notify(
                title: "90% of your \(period.title.lowercased()) cellular cap",
                body: "\(TrafficMonitor.bytes(used)) of \(TrafficMonitor.bytes(cap)) used \(period.noun)."
            )
        }
    }

    private func notify(title: String, body: String) {
        guard settings.value.budgetNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func progress(_ used: Int64, cap: Int64?) -> Double? {
        guard let cap, cap > 0 else { return nil }
        return min(Double(used) / Double(cap), 1)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(usage) {
            AppGroup.sharedDefaults.set(data, forKey: storageKey)
        }
    }
}

/// Shows budget notifications as banners while the app is in the foreground.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
