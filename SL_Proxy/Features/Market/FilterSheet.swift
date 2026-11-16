import SwiftUI

/// Filter modal: Country, State, City, ZIP, ISP. Edits a draft; "Apply" commits it to the list.
struct FilterSheet: View {
    @ObservedObject var market: MarketStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MarketStore.Filters()

    var body: some View {
        NavigationStack {
            Form {
                Section("Country") {
                    Picker("Country", selection: $draft.country) {
                        Text("Any").tag("")
                        ForEach(market.facets?.countries ?? []) { country in
                            Text("\(country.flag) \(country.name)").tag(country.code)
                        }
                    }
                }
                Section("Location") {
                    FacetRow(title: "State", options: market.facets?.states ?? [], selection: $draft.state)
                    FacetRow(title: "City", options: market.facets?.cities ?? [], selection: $draft.city)
                    HStack {
                        Text("ZIP")
                        TextField("Any", text: $draft.zip)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section("Network") {
                    FacetRow(title: "ISP", options: market.facets?.isps ?? [], selection: $draft.isp)
                }
                Section {
                    Button("Reset Filters", role: .destructive) { draft = MarketStore.Filters() }
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        market.filters = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = market.filters }
            .task { await market.loadFacets() }
        }
        .presentationDetents([.large])
    }
}

/// A row that opens a searchable list of the values the server actually has.
private struct FacetRow: View {
    let title: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        NavigationLink {
            FacetList(title: title, options: options, selection: $selection)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selection.isEmpty ? "Any" : selection)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct FacetList: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [String] {
        let term = search.trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        List {
            Button {
                selection = ""
                dismiss()
            } label: {
                HStack {
                    Text("Any")
                    Spacer()
                    if selection.isEmpty { Image(systemName: "checkmark").foregroundStyle(Brand.orange) }
                }
            }
            .buttonStyle(.plain)
            ForEach(shown, id: \.self) { value in
                Button {
                    selection = value
                    dismiss()
                } label: {
                    HStack {
                        Text(value)
                        Spacer()
                        if selection == value { Image(systemName: "checkmark").foregroundStyle(Brand.orange) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $search, prompt: "Search \(title.lowercased())")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
