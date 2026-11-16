import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showAddRule = false
    @State private var showAddRuleSet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    Section {
                        Picker("Mode", selection: $settings.value.routingMode) {
                            ForEach(RoutingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(settings.value.routingMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Routing mode")
                    }

                    Section {
                        Toggle("Bypass LAN and private IPs", isOn: $settings.value.bypassLAN)
                        Toggle("Bypass China domains and IPs", isOn: $settings.value.bypassChina)
                            .disabled(settings.value.routingMode != .rule)
                        Toggle("Block ads and trackers", isOn: $settings.value.blockAds)
                    } header: {
                        Text("Bypass and blocking")
                    } footer: {
                        Text("China bypass applies in Rule mode. Geo rule sets are downloaded through the proxy on first connect.")
                    .font(.caption2)
                    }

                    // Custom rules
                    Section {
                        if settings.value.customRules.isEmpty {
                            Text("No custom rules")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(settings.value.customRules) { rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.value)
                                        .font(.body.monospaced())
                                        .lineLimit(1)
                                    Text(rule.kind.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(rule.action.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(color(for: rule.action).opacity(0.18), in: Capsule())
                                    .foregroundStyle(color(for: rule.action))
                            }
                        }
                        .onDelete { offsets in
                            settings.value.customRules.remove(atOffsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text("Custom rules")
                            Spacer()
                            Button { showAddRule = true } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Brand.gradient)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Custom rules are evaluated in order before the mode default. Separate multiple values with commas.")
                    .font(.caption2)
                    }

                    // Remote rule sets
                    Section {
                        if settings.value.remoteRuleSets.isEmpty {
                            Text("No remote rule sets")
                                .foregroundStyle(.secondary)
                        }
                        ForEach($settings.value.remoteRuleSets) { $rrs in
                            HStack(spacing: 12) {
                                Toggle("", isOn: $rrs.enabled)
                                    .labelsHidden()
                                    .tint(Brand.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rrs.tag)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(rrs.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { offsets in
                            settings.value.remoteRuleSets.remove(atOffsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text("Remote Rule Sets")
                            Spacer()
                            Button { showAddRuleSet = true } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Brand.gradient)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Compiled .srs rule-set files downloaded through the proxy on first connect. Each enabled set routes matching traffic through the proxy.")
                    .font(.caption2)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Rules")
            .sheet(isPresented: $showAddRule) {
                AddRuleSheet { rule in
                    settings.value.customRules.append(rule)
                }
            }
            .sheet(isPresented: $showAddRuleSet) {
                AddRemoteRuleSetSheet { rrs in
                    settings.value.remoteRuleSets.append(rrs)
                }
            }
        }
    }

    private func color(for action: RuleAction) -> Color {
        switch action {
        case .proxy: return Brand.orange
        case .direct: return .green
        case .block: return .red
        }
    }
}

struct AddRuleSheet: View {
    let onAdd: (CustomRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RuleKind = .domainSuffix
    @State private var value = ""
    @State private var action: RuleAction = .proxy

    private var canAdd: Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    Section("Match") {
                        Picker("Type", selection: $kind) {
                            ForEach(RuleKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        TextField(kind.placeholder, text: $value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Section("Action") {
                        Picker("Action", selection: $action) {
                            ForEach(RuleAction.allCases) { action in
                                Text(action.title).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(CustomRule(kind: kind, value: value.trimmingCharacters(in: .whitespaces), action: action))
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
