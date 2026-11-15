import SwiftUI

/// Carrier Profile: what the SIM reports, which carrier the app matched (or the manual override),
/// the install link for the pipeline-generated `.mobileconfig`, and the live verification state.
struct CarrierProfileView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var nodes: NodeStore

    @State private var detection = CarrierDetector.detect()
    /// Text mirror of `settings.value.carrierProfileBaseURL`; committed on submit / leave.
    @State private var baseURLText = ""

    private var carrier: Carrier? { settings.value.carrierOverride ?? detection.carrier }

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    LabeledContent("SIM", value: detection.hasSIM ? (detection.carrierName ?? "Unnamed") : "None")
                    LabeledContent("MCC / MNC", value: detection.codeText)
                    if let radio = detection.radioTechnology {
                        LabeledContent("Radio", value: radio)
                    }
                    LabeledContent("Matched carrier", value: detection.carrier?.title ?? "No match")
                    Button {
                        detection = CarrierDetector.detect()
                    } label: {
                        Label("Detect again", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Auto-detect")
                } footer: {
                    Text(detectionFooter)
                }

                Section {
                    Picker("Carrier", selection: $settings.value.carrierOverride) {
                        Text("Automatic").tag(Carrier?.none)
                        ForEach(Carrier.allCases) { carrier in
                            Text(carrier.title).tag(Carrier?.some(carrier))
                        }
                    }
                } header: {
                    Text("Profile carrier")
                } footer: {
                    Text("Automatic follows the SIM match above. Pick a carrier by hand when iOS hides the codes or you use a different SIM for data.")
                }

                Section {
                    if let carrier {
                        LabeledContent("APN", value: carrier.apn)
                        LabeledContent("APN login", value: carrier.apnLoginSummary)
                        LabeledContent("Proxy", value: "\(AppSettings.localProxyHost):\(AppSettings.defaultLocalProxyPort)")
                        LabeledContent("File", value: carrier.profileFileName)
                        if let url = settings.value.carrierProfileURL(for: carrier) {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("Install Your \(carrier.title) Profile", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(BrandButtonStyle())
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                nodes.toast = "Profile link copied"
                            } label: {
                                Label("Copy download link", systemImage: "doc.on.doc")
                            }
                        } else {
                            Label("The profile source below is not a valid http(s) URL.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Pick a carrier above to get its profile.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let universalURL = settings.value.universalCarrierProfileURL {
                        Button {
                            UIApplication.shared.open(universalURL)
                        } label: {
                            Label("Install Universal Profile (all carriers)", systemImage: "square.stack.3d.down.right")
                        }
                        .buttonStyle(BrandButtonStyle())
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Install Your Carrier Profile")
                } footer: {
                    Text(installFooter)
                }

                Section {
                    Button(role: .destructive) {
                        resetAPN()
                    } label: {
                        Label("Reset APN", systemImage: "arrow.uturn.backward")
                    }
                } header: {
                    Text("Reset APN")
                } footer: {
                    Text(resetFooter)
                }

                Section {
                    TextField("https://…/build/ipa", text: $baseURLText)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { commitBaseURL() }
                    Button("Reset to pipeline artifacts") {
                        baseURLText = AppSettings.defaultCarrierProfileBaseURL
                        commitBaseURL()
                    }
                    .disabled(baseURLText == AppSettings.defaultCarrierProfileBaseURL)
                } header: {
                    Text("Profile source")
                } footer: {
                    Text("Directory the four .mobileconfig files are downloaded from. The default is the latest build_ipa artifact of feature/advanced-plus-ui; the ?job= parameter is added automatically for GitLab artifact URLs.")
                }

                VerificationSection(verifier: tunnel.verifier, path: tunnel.path, endpoint: tunnel.proxyEndpoint)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Carrier Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            detection = CarrierDetector.detect()
            baseURLText = settings.value.carrierProfileBaseURL
        }
        .onDisappear {
            commitBaseURL()
        }
    }

    // MARK: - Text

    private var detectionFooter: String {
        if !detection.hasSIM {
            return "No cellular plan is visible to the app. Insert a SIM or activate an eSIM, then detect again."
        }
        if detection.isPlaceholder {
            return "iOS 16.4 and later report the placeholder 65535 instead of the real MCC/MNC to apps, so the SIM cannot be matched automatically. Choose the carrier below."
        }
        if detection.carrier == nil {
            return "Nigeria is MCC 621; Airtel is MNC 20, MTN 30, Glo 50 and 9mobile 60. This SIM matched none of them."
        }
        return "Matched by MCC/MNC (Nigeria 621; Airtel 20, MTN 30, Glo 50, 9mobile 60) or by the carrier name."
    }

    private var installFooter: String {
        var text = "Opens the profile in Safari; iOS then offers it under Settings > Profile Downloaded. "
            + "The profile sets the APN (and its login where the carrier needs one) and points cellular data at the SL_Proxy listener, "
            + "so keep the proxy connected while it is installed. The Universal profile carries every carrier's APN, so it is the "
            + "simplest choice when you are unsure which SIM you will use. A private project asks you to sign in to GitLab first."
        if let carrier, carrier.apnUsername != nil {
            text += " \(carrier.title) rejects the APN without its login; if an older profile without it is installed, remove it and install this one again."
        }
        return text
    }

    private var resetFooter: String {
        "Clears the carrier override in the app and opens Settings so you can remove the installed "
            + "SL_Proxy cellular profile under VPN & Device Management. Removing it restores your "
            + "carrier's native APN; no reboot is needed once the profile is gone."
    }

    private func commitBaseURL() {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.value.carrierProfileBaseURL != trimmed { settings.value.carrierProfileBaseURL = trimmed }
    }

    /// Strips the app's carrier modifications and sends the user to the iOS profile list so the
    /// installed cellular profile can be removed, restoring the device's native carrier APN. Apps
    /// cannot delete a configuration profile programmatically, so this clears the in-app override
    /// and deep-links into Settings for the one manual step that remains.
    private func resetAPN() {
        settings.value.carrierOverride = nil
        detection = CarrierDetector.detect()
        nodes.toast = "APN override cleared. Remove the SL_Proxy profile in Settings to restore the native APN."
        if let url = URL(string: "App-Prefs:root=General&path=ManagedConfigurationList"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
    }
}

/// Live profile verification rows; split out so the nested observable objects are observed.
private struct VerificationSection: View {
    @ObservedObject var verifier: ProfileVerifier
    @ObservedObject var path: NetworkPathObserver
    let endpoint: String

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                ProfileVerifiedBadge(state: verifier.state)
            }
            LabeledContent("Device path", value: path.summary)
            LabeledContent("Listener \(endpoint)", value: reachability)
            LabeledContent("Loopback connections", value: "\(verifier.loopbackConnections)")
            if let seen = verifier.lastCellularTraffic {
                LabeledContent("Last cellular traffic", value: seen.formatted(date: .omitted, time: .standard))
            }
        } header: {
            Text("Profile verification")
        } footer: {
            Text(footer)
        }
    }

    private var reachability: String {
        switch verifier.listenerReachable {
        case .some(true): return "Reachable"
        case .some(false): return "Not reachable"
        case .none: return "Not checked"
        }
    }

    private var footer: String {
        var text = "While the proxy runs, the app connects to the listener socket and watches the sing-box connection table for loopback connections on the mixed-in inbound whose bytes move while the device is on cellular. That is the profile at work."
        if let error = verifier.lastError { text += " Last check failed: \(error)" }
        return text
    }
}
