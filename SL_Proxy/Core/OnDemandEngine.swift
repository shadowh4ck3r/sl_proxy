import Combine
import CoreTelephony
import Foundation
import Network
import SystemConfiguration.CaptiveNetwork

/// Evaluates the persisted `onDemandRules` whenever the network path changes and automatically
/// starts or stops the proxy engine. Rules are matched top-to-bottom; the first match wins.
/// A 1.5 s settle delay prevents rapid flapping when the path bounces.
@MainActor
final class OnDemandEngine: ObservableObject {
    @Published private(set) var isActive = false

    private weak var tunnel: TunnelController?
    private weak var settings: SettingsStore?
    private var pathCancellable: AnyCancellable?
    private var settleTask: Task<Void, Never>?

    init(tunnel: TunnelController, settings: SettingsStore) {
        self.tunnel = tunnel
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        // Subscribe to every path change published by the shared NWPathMonitor.
        pathCancellable = NetworkPathObserver.shared.$lastChange
            .dropFirst()          // skip the initial nil
            .compactMap { $0 }    // only real Date values
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleEvaluation()
            }
    }

    func stop() {
        isActive = false
        pathCancellable = nil
        settleTask?.cancel()
        settleTask = nil
    }

    // MARK: - Evaluation

    private func scheduleEvaluation() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // Settle delay: wait for the path to stabilise before acting.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        guard let tunnel, let settings else { return }
        guard settings.value.onDemandEnabled, !settings.value.onDemandRules.isEmpty else { return }
        // Do not interrupt a transition already in progress.
        guard tunnel.status == .running || tunnel.status == .stopped else { return }

        let path = NetworkPathObserver.shared
        let ssid = currentSSID()
        let carrierName = currentCarrierName()

        for rule in settings.value.onDemandRules {
            let name = rule.networkName.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches: Bool
            switch rule.interface {
            case .wifiSSID:
                guard path.isWiFi else { continue }
                matches = name.isEmpty || ssid?.lowercased() == name.lowercased()
            case .cellularNetwork:
                guard path.isCellular else { continue }
                matches = name.isEmpty || carrierName?.lowercased().contains(name.lowercased()) == true
            }
            guard matches else { continue }
            // First matching rule wins.
            switch rule.action {
            case .connect:
                if tunnel.status == .stopped { await tunnel.start() }
            case .disconnect:
                if tunnel.status == .running { await tunnel.stop() }
            case .ignore:
                break
            }
            return
        }
    }

    // MARK: - Network info helpers

    /// Current Wi-Fi SSID via CNCopyCurrentNetworkInfo (requires location permission or
    /// com.apple.developer.networking.wifi-info entitlement; returns nil when unavailable).
    private func currentSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for iface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
               let ssid = info[kCNNetworkInfoKeySSID as String] as? String,
               !ssid.isEmpty {
                return ssid
            }
        }
        return nil
    }

    /// Carrier name from CoreTelephony (best-effort; returns nil on iOS 16.4+ without real codes).
    private func currentCarrierName() -> String? {
        let info = CTTelephonyNetworkInfo()
        let providers = info.serviceSubscriberCellularProviders ?? [:]
        let dataKey = info.dataServiceIdentifier
        let provider = (dataKey.flatMap { providers[$0] }) ?? providers.values.first
        let name = provider?.carrierName
        guard let name, !name.isEmpty, name != "--" else { return nil }
        return name
    }
}
