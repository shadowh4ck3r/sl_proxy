import SwiftUI

/// Paste one or more share links (or a Base64 subscription body) and import them.
struct AddConfigSheet: View {
    @EnvironmentObject private var nodes: NodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: ImportResult?

    private var canImport: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Paste share links, one per line, or a Base64 encoded list.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $text)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Brand.gradient, lineWidth: 1)
                                    .opacity(0.5)
                            )

                        Text("Supported: " + ProxyURLParser.supportedSchemes.map { $0 + "://" }.joined(separator: "  "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let result {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.summary)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(result.added > 0 ? .primary : Color.red)
                                ForEach(result.failures.prefix(5), id: \.self) { failure in
                                    Text(failure)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 14)
                        }

                        Button("Import") { importNow() }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(!canImport)
                            .opacity(canImport ? 1 : 0.5)
                    }
                    .padding()
                }
            }
            .navigationTitle("Add servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let clipboard = UIPasteboard.general.string { text = clipboard }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            }
        }
    }

    private func importNow() {
        let outcome = nodes.importText(text)
        result = outcome
        if outcome.added > 0 {
            nodes.toast = outcome.summary
            dismiss()
        }
    }
}
