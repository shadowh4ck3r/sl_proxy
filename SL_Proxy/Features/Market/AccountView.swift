import SafariServices
import SwiftUI

/// In-app Safari for the website (Top Up Wallet).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// "Connect SailorsLoot Account": login form when signed out, account summary when signed in.
/// Reached from Settings and from the Proxies tab.
struct AccountView: View {
    @EnvironmentObject private var account: SLAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var password = ""
    @State private var showTopUp = false

    var body: some View {
        NavigationStack {
            Form {
                if account.isLoggedIn {
                    Section {
                        LabeledContent("Signed in as", value: account.username ?? "-")
                        LabeledContent("Wallet balance", value: account.balanceText)
                    }
                    Section {
                        Button {
                            Task { await account.refreshBalance() }
                        } label: {
                            Label("Refresh balance", systemImage: "arrow.clockwise")
                        }
                        topUpButton
                    }
                    Section {
                        Button("Disconnect account", role: .destructive) {
                            Task { await account.logout() }
                        }
                    } footer: {
                        Text("This revokes the login on the server and removes it from this iPhone.")
                    .font(.caption2)
                    }
                } else {
                    Section {
                        TextField("Username or email", text: $identifier)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } header: {
                        Text("SailorsLoot account")
                    } footer: {
                        if let message = account.errorMessage {
                            Text(message).foregroundStyle(.red)
                        } else {
                            Text("Use the account you created on sailorsloot.xyz. Your password is only sent to sailorsloot.xyz over HTTPS and is never stored; the app keeps a revocable login token in the iOS Keychain.")
                        }
                    }
                    Section {
                        Button {
                            Task {
                                if await account.login(identifier: identifier, password: password) {
                                    password = ""
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if account.isBusy { ProgressView() } else { Text("Connect SailorsLoot Account").bold() }
                                Spacer()
                            }
                        }
                        .disabled(identifier.isEmpty || password.isEmpty || account.isBusy)
                        topUpButton
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("SailorsLoot Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showTopUp) {
                SafariView(url: SLConfig.topUpURL).ignoresSafeArea()
            }
            .onChange(of: showTopUp) { open in
                // Back from the website: the balance may have changed.
                if !open { Task { await account.refreshBalance() } }
            }
        }
    }

    private var topUpButton: some View {
        Button {
            showTopUp = true
        } label: {
            Label("Top Up Wallet", systemImage: "plus.circle")
        }
    }
}
