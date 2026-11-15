import SwiftUI

/// Subscription Settings: update behaviour and the User-Agent presented to subscription servers.
///
/// Every control binds straight to `AppSettings` through `SettingsStore`, so the choices persist
/// across launches. Nothing here touches the sing-box config or the running core.
struct SubscriptionSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    Toggle("Auto Update", isOn: $settings.value.subscriptionAutoUpdate)
                    Toggle("Show Announcements", isOn: $settings.value.showAnnouncements)
                    Toggle("Send HWID", isOn: $settings.value.sendHWID)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Auto Update refreshes subscriptions on launch. Show Announcements displays notices published by your providers. Send HWID attaches a per-install hardware identifier to subscription requests for providers that bind a plan to one device.")
                }

                Section {
                    Picker("User-Agent", selection: $settings.value.subscriptionUserAgentPreset) {
                        ForEach(UserAgentPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    if settings.value.subscriptionUserAgentPreset == .custom {
                        TextField(
                            "Custom User-Agent string",
                            text: $settings.value.customSubscriptionUserAgent,
                            axis: .vertical
                        )
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sent as")
                        Text(settings.value.effectiveSubscriptionUserAgent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("User-Agent")
                } footer: {
                    Text(userAgentFooter)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var userAgentFooter: String {
        var text = "The User-Agent header identifies this app to subscription servers when servers are updated. "
            + "Pick a browser preset to mask the fingerprint, or Custom Entry to send any string."
        if settings.value.subscriptionUserAgentPreset == .custom,
           settings.value.customSubscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += " The custom entry is empty, so the app default is sent until you fill it in."
        }
        return text
    }
}
