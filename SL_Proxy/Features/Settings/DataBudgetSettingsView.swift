import SwiftUI

/// Data Budget: daily and monthly caps on the bytes proxied over cellular, what happens when they
/// are hit, and the current usage. Counting itself lives in `DataBudgetTracker`.
struct DataBudgetSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        DataBudgetForm(settings: settings, budget: tunnel.budget, path: tunnel.path)
    }
}

/// Split out so the nested `DataBudgetTracker` is observed directly.
private struct DataBudgetForm: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var budget: DataBudgetTracker
    @ObservedObject var path: NetworkPathObserver
    @State private var confirmReset = false

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    Toggle("Data Budget", isOn: $settings.value.dataBudgetEnabled)
                } footer: {
                    Text("Counts the bytes the proxy moves while this device is on cellular (Wi-Fi traffic is ignored). Usage is kept across launches and resets at midnight and on the first of the month.")
                }

                Section {
                    CapField(title: "Daily cap", megabytes: $settings.value.dailyCapMB)
                    CapField(title: "Monthly cap", megabytes: $settings.value.monthlyCapMB)
                } header: {
                    Text("Caps (MB)")
                } footer: {
                    Text("1 MB = 1,000,000 bytes, matching the totals shown on Home. Enter 0 to turn a cap off.")
                }

                Section {
                    Toggle("Notify at 90% and 100%", isOn: $settings.value.budgetNotifications)
                    if settings.value.budgetNotifications, budget.notificationsAuthorized == false {
                        Button {
                            Task { await budget.requestAuthorization() }
                        } label: {
                            Label("Allow notifications", systemImage: "bell.badge")
                        }
                    }
                    Toggle("Disconnect at 100%", isOn: $settings.value.budgetAutoDisconnect)
                } header: {
                    Text("When a cap is reached")
                } footer: {
                    Text(actionsFooter)
                }

                Section {
                    ForEach(DataBudgetTracker.Period.allCases, id: \.self) { period in
                        if let cap = budget.cap(for: period) {
                            BudgetBar(title: period.title, used: budget.bytes(for: period), cap: cap)
                                .padding(.vertical, 4)
                        } else {
                            LabeledContent("\(period.title) used", value: TrafficMonitor.bytes(budget.bytes(for: period)))
                        }
                    }
                    LabeledContent("Device path", value: path.summary)
                    if let event = budget.lastEvent {
                        Text(event)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Reset usage", role: .destructive) { confirmReset = true }
                } header: {
                    Text("Cellular usage")
                } footer: {
                    Text(usageFooter)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Data Budget")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            budget.refresh()
            Task { await budget.refreshAuthorization() }
        }
        .onChange(of: settings.value.dataBudgetEnabled) { enabled in
            if enabled, settings.value.budgetNotifications, budget.notificationsAuthorized != true {
                Task { await budget.requestAuthorization() }
            }
        }
        .onChange(of: settings.value.budgetNotifications) { enabled in
            if enabled, budget.notificationsAuthorized != true {
                Task { await budget.requestAuthorization() }
            }
        }
        .confirmationDialog("Reset cellular usage?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset today and this month", role: .destructive) { budget.resetUsage() }
        }
    }

    private var actionsFooter: String {
        var text = "At 90% a local notification warns you. At 100% another notification is posted"
        text += settings.value.budgetAutoDisconnect
            ? " and the engine disconnects; connecting again on cellular is refused until the period rolls over, the cap is raised or usage is reset."
            : "; the proxy keeps running."
        if budget.notificationsAuthorized == false {
            text += " Notifications are currently not allowed for SL_Proxy."
        }
        return text
    }

    private var usageFooter: String {
        if let period = budget.exceededPeriod {
            return "The \(period.title.lowercased()) cap is reached."
        }
        return path.isCellular
            ? "On cellular now: proxied bytes are being counted."
            : "Not on cellular: nothing is being counted right now."
    }
}

/// Integer MB editor; 0 means no cap.
private struct CapField: View {
    let title: String
    @Binding var megabytes: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            TextField("0", value: $megabytes, format: .number.grouping(.never))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .frame(maxWidth: 120)
            Text("MB")
                .foregroundStyle(.secondary)
        }
        .onChange(of: megabytes) { value in
            if value < 0 { megabytes = 0 }
        }
    }
}
