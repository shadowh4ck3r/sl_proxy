import SwiftUI

/// iCloud Backup (Advanced & Pro): live view of the `NSUbiquitousKeyValueStore` mirror kept by
/// `ICloudBackupStore`. Servers, subscriptions, rules and application options are uploaded
/// automatically whenever they change; this screen shows the result and offers a manual push.
struct ICloudBackupView: View {
    @EnvironmentObject private var backup: ICloudBackupStore
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    statusCard
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                    Button {
                        backup.backUpNow()
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .disabled(backup.status == .syncing)
                    if backup.status.isError {
                        Button {
                            backup.start()
                        } label: {
                            Label("Retry Connection", systemImage: "arrow.clockwise.icloud")
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text(statusFooter)
                }

                Section {
                    coverageRow("Servers", systemImage: "server.rack", value: "\(nodes.manualNodes.count)")
                    coverageRow("Subscriptions", systemImage: "link.icloud", value: "\(nodes.subscriptions.count)")
                    coverageRow("Rules", systemImage: "arrow.triangle.branch", value: "\(settings.value.customRules.count)")
                    coverageRow("On-Demand Rules", systemImage: "bolt.horizontal.circle", value: "\(settings.value.onDemandRules.count)")
                    coverageRow("Application Options", systemImage: "gearshape", value: "All")
                } header: {
                    Text("What Is Backed Up")
                } footer: {
                    Text(coverageFooter)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("iCloud Backup")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: backup.status)
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: backup.status.systemImage)
                .font(.title2)
                .foregroundStyle(backup.status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(Brand.gradient))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(backup.status.isError ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let device = backup.lastRemoteDevice, !backup.status.isError {
                    Text("Last written by \(device)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if backup.status == .syncing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .navigationStyleCard(settings.value.navigationStyle, cornerRadius: 18)
    }

    private var statusFooter: String {
        if backup.status.isError {
            return "Servers, subscriptions, rules and options stay on this device and are uploaded automatically as soon as iCloud becomes available."
        }
        return "Changes to servers, subscriptions, rules and options are uploaded to your iCloud account automatically and restored on your other devices running SL_Proxy."
    }

    // MARK: - Coverage

    private func coverageRow(_ title: String, systemImage: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private var coverageFooter: String {
        var text = ""
        if backup.payloadBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: Int64(backup.payloadBytes), countStyle: .file)
            text += "Last snapshot: \(size). "
        }
        text += "Stored as one snapshot in your iCloud key-value store (1 MB limit). Server latency results are not included."
        return text
    }
}
