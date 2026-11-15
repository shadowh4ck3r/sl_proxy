import SwiftUI

/// Country / State / City / ZIP / ISP filters for the proxy list. The pickers are filled from the
/// server (`proxies/filters`) and narrow each other: choosing a country limits the states, cities
/// and ISPs to that country.
struct MarketFilterSheet: View {
    @EnvironmentObject private var market: ProxyMarketStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProxyMarketStore.Filter()

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    picker("Country", selection: $draft.country, values: market.options.countries) { code in
                        "\(flag(code)) \(marketCountryName(code))"
                    }
                    picker("State", selection: $draft.state, values: market.options.states) { $0 }
                    picker("City", selection: $draft.city, values: market.options.cities) { $0 }
                    TextField("ZIP starts with", text: $draft.zip)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                Section("Network") {
                    picker("ISP", selection: $draft.isp, values: market.options.isps) { $0 }
                }
                Section {
                    Button("Reset filters", role: .destructive) {
                        draft = ProxyMarketStore.Filter()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        market.filter = draft
                        dismiss()
                        Task { await market.reload() }
                    }
                }
            }
            .onAppear { draft = market.filter }
            .task { await market.loadOptions(country: market.filter.country, state: market.filter.state) }
            // Narrow the lists below as soon as a country or state is chosen.
            .onChange(of: draft.country) { value in
                Task { await market.loadOptions(country: value, state: "") }
            }
            .onChange(of: draft.state) { value in
                Task { await market.loadOptions(country: draft.country, state: value) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars
            .compactMap { UnicodeScalar(127_397 + $0.value) }
            .map { String($0) }
            .joined()
    }

    private func picker(_ title: String, selection: Binding<String>, values: [String],
                        label: @escaping (String) -> String) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag("")
            ForEach(values, id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
    }
}
