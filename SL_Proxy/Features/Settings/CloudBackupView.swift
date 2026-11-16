import SwiftUI

/// iCloud Backup screen: Auto Sync switch, Back Up Now, and every backup that exists in iCloud.
/// Tap a backup to restore it; swipe to delete.
struct CloudBackupView: View {
    @EnvironmentObject private var nodes: NodeStore
    @ObservedObject private var cloud = SLCloudSync.shared
    @State private var pending: SLCloudSync.Backup?

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    Toggle("Auto Sync", isOn: $cloud.autoSync)
                        .disabled(!cloud.isAvailable)
                    if let last = cloud.lastSync {
                        HStack {
                            Text("Last sync")
                            Spacer()
                            Text(last, style: .relative).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    Button {
                        Task { await cloud.backUpNow() }
                    } label: {
                        HStack {
                            Text("Back Up Now")
                            Spacer()
                            if cloud.isBusy { ProgressView() }
                        }
                    }
                    .disabled(!cloud.isAvailable || cloud.isBusy)
                } footer: {
                    Text(cloud.isAvailable
                         ? "Auto Sync saves your servers to iCloud a few seconds after you change them. A new install with an empty list restores the latest backup by itself."
                         : "iCloud is not available. Sign in to iCloud and turn on iCloud Drive for SL_Proxy.")
                        .guideFooter()
                }

                Section {
                    if cloud.backups.isEmpty {
                        Text(cloud.isAvailable ? "No backups yet" : "-")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cloud.backups) { backup in
                        Button { pending = backup } label: {
                            HStack(spacing: 12) {
                                Image(systemName: backup.isAuto ? "arrow.triangle.2.circlepath.icloud" : "icloud.and.arrow.up")
                                    .foregroundStyle(Brand.gradient)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.weight(.medium))
                                    Text("\(backup.device) · \(backup.serverCount) servers\(backup.isAuto ? " · auto" : "")")
                                        .guideText()
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await cloud.delete(backup) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Available Backups")
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await cloud.refresh() }
        }
        .navigationTitle("iCloud Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            cloud.attach(to: nodes)
            await cloud.refresh()
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { backup in
            Button("Replace my servers with this backup", role: .destructive) { cloud.restore(backup) }
        } message: { backup in
            Text("\(backup.serverCount) servers from \(backup.device). Your current list will be replaced.")
        }
        .alert("iCloud", isPresented: Binding(
            get: { cloud.message != nil }, set: { if !$0 { cloud.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloud.message ?? "")
        }
    }
}
