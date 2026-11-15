import SwiftUI

struct AddSubscriptionSheet: View {
    @EnvironmentObject private var nodes: NodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var isAdding = false

    private var canAdd: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    Section {
                        TextField("Name (optional)", text: $name)
                        TextField("https://example.com/sub?token=…", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Subscription")
                    } footer: {
                        Text("Base64 lists and plain lists of share links are supported. Servers are replaced on every refresh.")
                    }
                    Section {
                        Button {
                            if let clipboard = UIPasteboard.general.string { url = clipboard }
                        } label: {
                            Label("Paste URL from clipboard", systemImage: "doc.on.clipboard")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add") { add() }.disabled(!canAdd)
                    }
                }
            }
        }
    }

    private func add() {
        isAdding = true
        Task {
            await nodes.addSubscription(name: name, url: url)
            isAdding = false
            dismiss()
        }
    }
}
