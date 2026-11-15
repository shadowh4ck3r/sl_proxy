import SwiftUI

/// Sheet for adding a new remote rule-set entry (Rules tab > Remote Rule Sets > +).
struct AddRemoteRuleSetSheet: View {
    let onAdd: (RemoteRuleSet) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tag = ""
    @State private var url = ""

    private var canAdd: Bool {
        !tag.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty &&
        URL(string: url.trimmingCharacters(in: .whitespaces)) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    Section {
                        TextField("e.g. my-blocklist", text: $tag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Tag")
                    } footer: {
                        Text("A short identifier used in the sing-box config. Must be unique.")
                    }

                    Section {
                        TextField("https://example.com/rules.srs", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("URL")
                    } footer: {
                        Text("Direct link to a compiled .srs (sing-box rule-set binary) file. The engine downloads and caches it on first connect.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Rule Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(RemoteRuleSet(
                            tag: tag.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces)
                        ))
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
