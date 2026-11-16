import SwiftUI

/// Advanced & Pro Settings: hub for the pro sub-screens plus the Combine WiFi + Cellular controls.
///
/// Every control binds straight to `AppSettings` through `SettingsStore`, so the choices persist
/// across launches. The combine values are stored for the hybrid routing engine and do not reach
/// the sing-box config yet, so changing them never restarts the running core.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    NavigationLink {
                        ProxyShareSettingsView()
                    } label: {
                        Label("Proxy Share Settings", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        OnDemandSettingsView()
                    } label: {
                        Label("On Demand Settings", systemImage: "bolt.horizontal.circle")
                    }
                    NavigationLink {
                        ICloudBackupView()
                    } label: {
                        Label("iCloud Backup", systemImage: "icloud")
                    }
                    NavigationLink {
                        CarrierProfileView()
                    } label: {
                        Label("Carrier Profile", systemImage: "simcard")
                    }
                    NavigationLink {
                        DataBudgetSettingsView()
                    } label: {
                        Label("Data Budget", systemImage: "gauge.medium")
                    }
                    NavigationLink {
                        AutoSwitchSettingsView()
                    } label: {
                        Label("Auto Node Switching", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Pro")
                }

                Section {
                    Toggle("Combine WiFi + Cellular", isOn: $settings.value.combineWiFiCellular)
                    Toggle("Auto Ratio", isOn: $settings.value.combineAutoRatio)
                        .disabled(!settings.value.combineWiFiCellular)
                    if !settings.value.combineAutoRatio {
                        RatioSlider(
                            title: "WiFi Ratio",
                            systemImage: "wifi",
                            value: $settings.value.wifiRatio
                        )
                        RatioSlider(
                            title: "Cellular Ratio",
                            systemImage: "antenna.radiowaves.left.and.right",
                            value: $settings.value.cellularRatio
                        )
                    }
                } header: {
                    Text("Combine WiFi + Cellular")
                } footer: {
                    Text(combineFooter)
                    .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
            .animation(.easeInOut(duration: 0.2), value: settings.value.combineAutoRatio)
        }
        .navigationTitle("Advanced & Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var combineFooter: String {
        var text = "Multipath TCP / sing-box hybrid routing: use both links at once and steer traffic between them."
        if settings.value.combineAutoRatio {
            text += " Auto Ratio lets the engine balance the two links from their measured quality."
        } else {
            text += " WiFi \(settings.value.wifiRatio)% and Cellular \(settings.value.cellularRatio)% are stored independently; "
                + "they do not need to add up to 100%."
        }
        text += " These values are saved for the hybrid engine and are not applied to the running core yet."
        return text
    }
}

/// Horizontal 0...100% slider with a live read-out, styled with the brand tint.
private struct RatioSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                Spacer()
                Text("\(value)%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Brand.gradient)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = AppSettings.clampRatio(Int($0.rounded())) }
                ),
                in: Double(AppSettings.ratioRange.lowerBound)...Double(AppSettings.ratioRange.upperBound),
                step: 1
            ) {
                Text(title)
            } minimumValueLabel: {
                Text("0%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("100%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tint(Brand.orange)
        }
        .padding(.vertical, 2)
    }
}
