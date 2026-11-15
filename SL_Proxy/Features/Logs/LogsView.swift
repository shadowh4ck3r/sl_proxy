import SwiftUI

/// Streams the tunnel extension's log buffer over provider messages.
struct LogsView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @State private var lines: [TunnelLogLine] = []
    @State private var nextIndex = 0
    @State private var paused = false

    /// True when pushed from Settings (already inside a NavigationStack).
    var embedded = false

    @ViewBuilder
    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        Group {
            ZStack {
                Brand.background
                if lines.isEmpty {
                    EmptyStateCard(
                        icon: "doc.text.magnifyingglass",
                        title: "No logs yet",
                        message: tunnel.isConnected || tunnel.isTransitioning
                            ? "Waiting for the tunnel to report…"
                            : (tunnel.lastError.map { "Last start failed:\n\($0)" }
                                ?? "Connect from the Home tab to see live logs from the sing-box core.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        List(lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.date, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(line.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: line.message))
                                    .textSelection(.enabled)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .id(line.id)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: lines.count) { _ in
                            guard !paused, let last = lines.last else { return }
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { paused.toggle() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = lines.map { "\(Self.timeFormatter.string(from: $0.date)) \($0.message)" }.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(lines.isEmpty)
                    Button {
                        lines.removeAll()
                        Task { _ = await tunnel.send(.clearLogs) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(lines.isEmpty)
                }
            }
            .task { await poll() }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func color(for message: String) -> Color {
        let lowered = message.lowercased()
        if lowered.contains("error") || lowered.contains("fatal") { return .red }
        if lowered.contains("warn") { return Brand.gold }
        return .primary
    }

    private func poll() async {
        while !Task.isCancelled {
            if !paused, let reply = await tunnel.send(.logs(after: nextIndex)) {
                if reply.nextLogIndex < nextIndex {
                    // The extension restarted and its buffer was reset.
                    lines.removeAll()
                    nextIndex = 0
                }
                let fresh = reply.logs.filter { $0.id >= nextIndex }
                if !fresh.isEmpty {
                    lines.append(contentsOf: fresh)
                    if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
                }
                nextIndex = max(nextIndex, reply.nextLogIndex)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
