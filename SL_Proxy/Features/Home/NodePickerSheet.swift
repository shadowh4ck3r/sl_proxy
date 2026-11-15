import SwiftUI

/// Quick server switcher presented from the Home tab.
struct NodePickerSheet: View {
    @EnvironmentObject private var nodes: NodeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                if nodes.nodes.isEmpty {
                    EmptyStateCard(
                        icon: "server.rack",
                        title: "No servers yet",
                        message: "Import servers from the Configs tab, then pick one here."
                    )
                } else {
                    List {
                        ForEach(nodes.nodes) { node in
                            NodeRow(
                                node: node,
                                isActive: node.id == nodes.activeNodeID,
                                isTesting: nodes.testingIDs.contains(node.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                nodes.select(node)
                                dismiss()
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Choose server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await nodes.testAll() }
                    } label: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .disabled(nodes.nodes.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
