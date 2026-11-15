import SwiftUI

/// Advanced & Pro > Auto Node Switching
///
/// When enabled, SingBoxConfigBuilder wraps all imported nodes in a sing-box `urltest` outbound
/// group. The group pings `urlTestURL` every `urlTestInterval` seconds and automatically detours
/// traffic through the fastest responding node. The live latency list below lets the user
/// manually re-run the test at any time.
struct AutoSwitchSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController

    @State private var latencies: [UUID: Int?] = [:]   // nil = testing, missing = not tested
    @State private var isTesting = false

    var body: some View {
        ZStack {
            Brand.background
            Form {
                // Master toggle
                Section {
                    Toggle("Auto Node Switching", isOn: $settings.value.autoNodeSwitching)
                } footer: {
                    Text("When on, all imported nodes are grouped into a sing-box urltest outbound. The engine pings each node and routes traffic through the fastest one automatically.")
                }

                if settings.value.autoNodeSwitching {
                    // Test URL
                    Section {
                        HStack {
                            Text("Test URL")
                            Spacer()
                            TextField("https://www.gstatic.com/generate_204",
                                      text: $settings.value.urlTestURL)
                                .multilineTextAlignment(.trailing)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Latency Test")
                    } footer: {
                        Text("The engine fetches this URL through each node to measure latency. A 204 endpoint is ideal.")
                    }

                    // Interval stepper
                    Section {
                        Stepper(
                            value: $settings.value.urlTestInterval,
                            in: 30...3600,
                            step: 30
                        ) {
                            HStack {
                                Text("Test Interval")
                                Spacer()
                                Text(intervalLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("How often the engine re-tests all nodes. Shorter intervals keep the selection fresh but use more data.")
                    }

                    // Live latency list
                    Section {
                        if nodes.nodes.isEmpty {
                            Text("No nodes imported yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(nodes.nodes) { node in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                            .lineLimit(1)
                                        Text("\(node.server):\(node.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    latencyBadge(for: node.id)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Nodes")
                            Spacer()
                            Button {
                                Task { await runLatencyTest() }
                            } label: {
                                Label(isTesting ? "Testing…" : "Test All",
                                      systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .disabled(isTesting || nodes.nodes.isEmpty)
                            .tint(Brand.orange)
                        }
                    } footer: {
                        Text("Tap \"Test All\" to measure TCP connect latency to each node right now. The engine uses its own internal test during operation.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Auto Node Switching")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private var intervalLabel: String {
        let s = settings.value.urlTestInterval
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let rem = s % 60
        return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
    }

    @ViewBuilder
    private func latencyBadge(for id: UUID) -> some View {
        if let entry = latencies[id] {
            if let ms = entry {
                Text("\(ms) ms")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(latencyColor(ms).opacity(0.18), in: Capsule())
                    .foregroundStyle(latencyColor(ms))
            } else {
                ProgressView().scaleEffect(0.7)
            }
        } else {
            Text("--")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return Brand.orange
        default: return .red
        }
    }

    private func runLatencyTest() async {
        isTesting = true
        defer { isTesting = false }
        // Mark all as "testing" (nil)
        for node in nodes.nodes { latencies[node.id] = .some(nil) }
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for node in nodes.nodes {
                group.addTask {
                    let ms = await LatencyTester.measure(host: node.server, port: node.port)
                    return (node.id, ms)
                }
            }
            for await (id, ms) in group {
                latencies[id] = .some(ms)
            }
        }
    }
}
