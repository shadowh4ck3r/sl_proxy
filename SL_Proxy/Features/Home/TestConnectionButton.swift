import SwiftUI

/// Probes the selected config with `ProxyPingTester` and shows the latency or "Server Unreachable".
struct TestConnectionButton: View {
    let config: String
    let scheme: String

    @State private var isTesting = false
    @State private var result: ProxyPingTester.Result?

    private var isUDPOnly: Bool { ["hysteria", "hysteria2", "hy2", "tuic"].contains(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: runTest) {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Brand.orange)
                .disabled(isTesting || config.isEmpty)

                Spacer()

                if isTesting {
                    ProgressView().controlSize(.small)
                } else if let result {
                    statusLabel(result)
                }
            }

            if case .offline(let error)? = result, !isTesting {
                Text(isUDPOnly
                    ? "\(error). This protocol uses UDP, so a TCP probe may not reflect the real state."
                    : error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runTest() {
        isTesting = true
        result = nil
        ProxyPingTester.shared.test(config: config) { outcome in
            result = outcome
            isTesting = false
        }
    }

    @ViewBuilder
    private func statusLabel(_ result: ProxyPingTester.Result) -> some View {
        switch result {
        case .online(let latencyMs, let throughProxy):
            Label(throughProxy ? "\(latencyMs) ms via proxy" : "\(latencyMs) ms", systemImage: "checkmark.circle.fill")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(latencyMs < 150 ? Color.green : Brand.gold)
        case .offline:
            Label("Server Unreachable", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }
}
