import SafariServices
import SwiftUI

/// In-app Safari for the wallet top up. Funding happens on the website, never inside the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Brand.orange)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

enum SailorsLootLinks {
    static let site = URL(string: "https://sailorsloot.xyz")!
    static let lostPassword = URL(string: "https://sailorsloot.xyz/my-account/lost-password/")!
}

/// "Connect SailorsLoot Account": sign in with the website username or email, see the wallet
/// balance, open the website to top up, and sign out. The same screen is used from Settings and
/// from the Proxy List when the user is signed out.
struct ConnectAccountView: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var login = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var showTopUp = false
    @FocusState private var focus: Field?

    private enum Field { case login, password }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                ScrollView {
                    VStack(spacing: 18) {
                        BrandLogo(height: 34).padding(.top, 8)
                        if account.isLoggedIn { signedIn } else { signedOut }
                        topUpButton
                        Text("Top up on the website, then pull to refresh your balance here. Your password is sent over HTTPS and is never stored; only a revocable access token is kept in the Keychain.")
                            .guideText()
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .padding()
                }
            }
            .navigationTitle("SailorsLoot Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showTopUp, onDismiss: { Task { await account.refreshBalance() } }) {
                SafariView(url: SailorsLootLinks.site).ignoresSafeArea()
            }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        VStack(spacing: 14) {
            Text("Connect SailorsLoot Account")
                .font(.headline)
            Text("Sign in to see your wallet, browse live proxies, buy one and connect in one tap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let notice = account.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Brand.orange)
            }

            VStack(spacing: 10) {
                TextField("Username or email", text: $login)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .focused($focus, equals: .login)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signIn() }
            } label: {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(isWorking || login.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            .opacity(login.isEmpty || password.isEmpty ? 0.6 : 1)

            Link("Forgot password?", destination: SailorsLootLinks.lostPassword)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Brand.orange)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 20, padding: 18)
    }

    // MARK: - Signed in

    private var signedIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(account.username)
                .font(.headline)
            VStack(spacing: 2) {
                Text("Wallet balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(account.balanceText)
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(Brand.gradient)
            }
            Button {
                Task { await account.refreshBalance() }
            } label: {
                Label("Refresh balance", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .disabled(account.isRefreshing)
            Button(role: .destructive) {
                Task { await account.logout() }
            } label: {
                Text("Sign Out")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 20, padding: 18)
        .task { await account.refreshBalance() }
    }

    private var topUpButton: some View {
        Button {
            showTopUp = true
        } label: {
            Label("Top Up Wallet", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func signIn() async {
        guard !isWorking else { return }
        focus = nil
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await account.login(login.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Row for the Settings list: shows the signed-in user or "Connect SailorsLoot Account".
/// Drop it into the Settings `List`/`Form`:  `AccountSettingsRow()`
struct AccountSettingsRow: View {
    @ObservedObject private var account = AccountStore.shared
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 12) {
                Image(systemName: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isLoggedIn ? account.username : "Connect SailorsLoot Account")
                        .font(.body.weight(.medium))
                    Text(account.isLoggedIn ? "Wallet \(account.balanceText)" : "Buy live proxies with your wallet")
                        .guideText()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) { ConnectAccountView() }
    }
}
