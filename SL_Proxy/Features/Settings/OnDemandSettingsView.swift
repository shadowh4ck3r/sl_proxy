import SwiftUI

/// On-Demand Settings: master switch plus the network rules the on-demand engine evaluates.
///
/// Rules live in `AppSettings.onDemandRules` through `SettingsStore` and persist across launches.
/// Matching them against the live network is wired in a later step; nothing here touches the
/// running core.
struct OnDemandSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    HStack {
                        Toggle("On Demand", isOn: $settings.value.onDemandEnabled)
                        if settings.value.onDemandEnabled {
                            Spacer()
                            Text(tunnel.onDemandActive ? "Active" : "Inactive")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (tunnel.onDemandActive ? Color.green : Color.secondary).opacity(0.18),
                                    in: Capsule()
                                )
                                .foregroundStyle(tunnel.onDemandActive ? .green : .secondary)
                        }
                    }
                } footer: {
                    Text("Connects or disconnects the proxy automatically when the device joins a network that matches a rule below. Rules are evaluated top to bottom; the first match wins.")
                }

                Section {
                    if settings.value.onDemandRules.isEmpty {
                        Text("No rules yet. Add one to react to a Wi-Fi network or carrier.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($settings.value.onDemandRules) { $rule in
                        OnDemandRuleCard(rule: $rule)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        settings.value.onDemandRules.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        settings.value.onDemandRules.move(fromOffsets: source, toOffset: destination)
                    }
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            settings.value.onDemandRules.append(OnDemandRule())
                        }
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                    .tint(Brand.orange)
                } header: {
                    Text("Rules")
                } footer: {
                    Text("Each card matches one network. Swipe a rule to delete it, or use Edit to reorder. Leave the name empty to match any network of that kind.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("On Demand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !settings.value.onDemandRules.isEmpty {
                EditButton()
            }
        }
    }
}

/// One rule: interface picker, network name and the action taken when the rule matches.
private struct OnDemandRuleCard: View {
    @Binding var rule: OnDemandRule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Interface", selection: $rule.interface) {
                ForEach(OnDemandInterfaceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Image(systemName: rule.interface.systemImage)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 22)
                TextField(rule.interface.placeholder, text: $rule.networkName)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Picker("Action", selection: $rule.action) {
                ForEach(OnDemandAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private var summary: String {
        let name = rule.networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = name.isEmpty
            ? "any \(rule.interface.subject)"
            : "\(rule.interface.subject) \"\(name)\""
        return "\(rule.action.title): \(rule.action.detail) when on \(target)."
    }
}
