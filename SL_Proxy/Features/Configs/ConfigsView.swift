import SwiftUI

struct ConfigsView: View {
    @EnvironmentObject private var nodes: NodeStore
    @State private var sheet: ConfigSheet?

    private enum ConfigSheet: Identifiable, Hashable {
        case paste, scan, subscription
        /// Manual editor; `nil` adds a new server, a node edits that server.
        case manual(ProxyNode?)
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                if nodes.nodes.isEmpty && nodes.subscriptions.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Configs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await nodes.testAll() }
                    } label: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .disabled(nodes.nodes.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) { addMenu }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .paste: AddConfigSheet()
                case .scan: QRScannerSheet()
                case .subscription: AddSubscriptionSheet()
                case .manual(let node): ManualConfigSheet(node: node)
                }
            }
        }
    }

    // MARK: - Pieces

    private var addMenu: some View {
        Menu {
            Button { sheet = .manual(nil) } label: {
                Label("Add server manually…", systemImage: "square.and.pencil")
            }
            Divider()
            Button { nodes.importFromClipboard() } label: {
                Label("Import from clipboard", systemImage: "doc.on.clipboard")
            }
            Button { sheet = .paste } label: {
                Label("Paste share links…", systemImage: "link")
            }
            Button { sheet = .scan } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            Divider()
            Button { sheet = .subscription } label: {
                Label("Add subscription", systemImage: "antenna.radiowaves.left.and.right")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(Brand.gradient)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateCard(
                icon: "square.and.arrow.down",
                title: "Add your first server",
                message: "Enter a server by hand, paste a share link, scan a QR code or add a subscription URL. Shadowsocks, VMess, VLESS, Trojan, SOCKS5, HTTP, Hysteria, Hysteria2, TUIC and WireGuard are supported."
            )
            HStack(spacing: 10) {
                quickAction("Manual", icon: "square.and.pencil") { sheet = .manual(nil) }
                quickAction("Clipboard", icon: "doc.on.clipboard") { nodes.importFromClipboard() }
                quickAction("Scan QR", icon: "qrcode.viewfinder") { sheet = .scan }
                quickAction("Subscribe", icon: "antenna.radiowaves.left.and.right") { sheet = .subscription }
            }
            .padding(.horizontal)
        }
    }

    private func quickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Brand.gradient)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        List {
            if !nodes.manualNodes.isEmpty {
                Section("Servers") {
                    ForEach(nodes.manualNodes) { node in row(node) }
                }
            }
            ForEach(nodes.subscriptions) { subscription in
                Section {
                    let members = nodes.nodes(in: subscription)
                    if members.isEmpty {
                        Text("No servers yet. Pull to refresh.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(members) { node in row(node) }
                } header: {
                    subscriptionHeader(subscription)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await nodes.refreshAll() }
    }

    private func row(_ node: ProxyNode) -> some View {
        let isActive = node.id == nodes.activeNodeID
        let isManual = node.subscriptionID == nil
        return NodeRow(node: node, isActive: isActive, isTesting: nodes.testingIDs.contains(node.id))
            .contentShape(Rectangle())
            .onTapGesture { nodes.select(node) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { nodes.delete(node) } label: {
                    Label("Delete", systemImage: "trash")
                }
                if isManual {
                    Button { sheet = .manual(node) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Brand.gold)
                }
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await nodes.testLatency(node) }
                } label: {
                    Label("Ping", systemImage: "bolt")
                }
                .tint(Brand.orange)
            }
            .contextMenu {
                if isManual {
                    Button { sheet = .manual(node) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                Button {
                    UIPasteboard.general.string = node.shareURL
                    nodes.toast = "Link copied"
                } label: {
                    Label("Copy share link", systemImage: "doc.on.doc")
                }
                .disabled(node.shareURL == nil)
                Button {
                    Task { await nodes.testLatency(node) }
                } label: {
                    Label("Test latency", systemImage: "bolt")
                }
                Button(role: .destructive) { nodes.delete(node) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Brand.gold.opacity(0.12) : Color(.secondarySystemGroupedBackground).opacity(0.6))
                    .padding(.vertical, 2)
            )
    }

    private func subscriptionHeader(_ subscription: Subscription) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                if let date = subscription.lastUpdated {
                    (Text("Updated ") + Text(date, style: .relative) + Text(" ago"))
                        .font(.caption2)
                }
            }
            Spacer()
            Text("\(nodes.nodes(in: subscription).count)")
                .font(.caption.monospacedDigit())
            if nodes.refreshingIDs.contains(subscription.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await nodes.refresh(subscription) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button {
                    UIPasteboard.general.string = subscription.url
                    nodes.toast = "Subscription URL copied"
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) { nodes.delete(subscription) } label: {
                    Label("Remove subscription", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .textCase(nil)
    }
}
