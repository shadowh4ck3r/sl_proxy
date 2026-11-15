import SwiftUI

/// Live list of the devices using the Proxy Share listener, grouped by source IP, with their
/// current throughput and session totals. Data comes from `ConnectedClientsMonitor`, which polls
/// the sing-box Clash API `/connections` snapshot once a second while sharing is active.
struct ConnectedClientsView: View {
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        ConnectedClientsList(
            monitor: tunnel.clients,
            endpoint: tunnel.shareEndpoint,
            isSharing: tunnel.activeShareAddress != nil
        )
    }
}

/// Split out so the nested `ConnectedClientsMonitor` is observed directly.
private struct ConnectedClientsList: View {
    @ObservedObject var monitor: ConnectedClientsMonitor
    let endpoint: String?
    let isSharing: Bool

    var body: some View {
        ZStack {
            Brand.background
            List {
                Section {
                    LabeledContent("Shared listener", value: endpoint ?? "Not running")
                    LabeledContent("Active devices", value: "\(monitor.activeCount)")
                    LabeledContent("Download", value: TrafficMonitor.rate(monitor.totalDownloadSpeed))
                    LabeledContent("Upload", value: TrafficMonitor.rate(monitor.totalUploadSpeed))
                } header: {
                    Text("Overview")
                } footer: {
                    Text(footer)
                }

                Section {
                    if monitor.clients.isEmpty {
                        Text(isSharing
                             ? "No device has connected yet. Point a tethered device at the shared listener."
                             : "Turn on sharing and connect to see devices here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(monitor.clients) { client in
                        ClientRow(client: client)
                    }
                } header: {
                    Text("Devices")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Connected Clients")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        var text = "Grouped by source IP from the sing-box connection table; refreshed every second. "
            + "Apps on this device using the loopback listener are not listed."
        if let error = monitor.lastError {
            text += " Last poll failed: \(error)"
        } else if !monitor.isPolling {
            text += " Polling is paused while sharing is off."
        }
        return text
    }
}

private struct ClientRow: View {
    let client: ConnectedClient

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: client.isActive ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.title3)
                .foregroundStyle(client.isActive ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(client.ip)
                    .font(.body.monospaced().weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !client.recentHosts.isEmpty {
                    Text(client.recentHosts.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("↓ " + TrafficMonitor.rate(client.downloadSpeed))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(Brand.gold)
                Text("↑ " + TrafficMonitor.rate(client.uploadSpeed))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(Brand.orange)
                Text(TrafficMonitor.bytes(client.downloadTotal + client.uploadTotal) + " total")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if client.isActive {
            parts.append(client.connections == 1 ? "1 connection" : "\(client.connections) connections")
        } else {
            parts.append("Idle since \(client.lastSeen.formatted(date: .omitted, time: .shortened))")
        }
        if !client.inbound.isEmpty { parts.append(client.inbound) }
        return parts.joined(separator: " · ")
    }
}
