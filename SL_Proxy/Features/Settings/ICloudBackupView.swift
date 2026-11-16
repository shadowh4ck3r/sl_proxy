import SwiftUI

/// iCloud Backup (Advanced & Pro): live view of the `NSUbiquitousKeyValueStore` mirror kept by
/// `ICloudBackupStore`. Servers, subscriptions, rules and application options are uploaded
/// automatically whenever they change; this screen shows the result and offers a manual push.
struct ICloudBackupView: View {
    @EnvironmentObject private var backup: ICloudBackupStore
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var pendingRestore: BackupSnapshot?

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
                    .font(.caption2)
                }

                Section {
                    Toggle("Auto Sync", isOn: $backup.autoSync)
                } footer: {
                    Text(backup.autoSync
                         ? "Changes are uploaded by themselves and a newer backup from another device is applied automatically."
                         : "Nothing is uploaded or applied until you tap Back Up Now or restore a backup below.")
                    .font(.caption2)
                }

                Section {
                    if backup.history.isEmpty {
                        Text("No backups yet. Tap Back Up Now to save one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(backup.history, id: \.savedAt) { snapshot in
                        Button {
                            pendingRestore = snapshot
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(snapshot.deviceName) \u{2022} \(snapshot.content.nodes.count) servers \u{2022} \(snapshot.content.subscriptions.count) subscriptions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                backup.deleteBackup(snapshot)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Backups")
                } footer: {
                    Text("Tap a backup to restore it. The last \(ICloudBackupStore.maxHistory) are kept: one per manual backup, plus one every few hours while Auto Sync is on.")
                    .font(.caption2)
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
                    .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let snapshot = pendingRestore { backup.restore(snapshot) }
                pendingRestore = nil
            }
        } message: {
            Text("Your current servers, subscriptions and options are replaced by this backup.")
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
