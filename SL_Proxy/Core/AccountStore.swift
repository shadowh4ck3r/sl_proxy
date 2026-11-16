import Foundation

/// Signed-in state of the sailorsloot.xyz account and the live wallet balance. The token itself
/// lives only in the Keychain (`KeychainManager`).
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var session: KeychainManager.Session?
    @Published private(set) var balance: Double?
    @Published private(set) var isRefreshing = false
    /// Views present `ConnectAccountView` while this is true (set after a 401 or from "Connect").
    @Published var showLogin = false
    @Published var notice: String?

    var isLoggedIn: Bool { session.map { !$0.isExpired } ?? false }
    var username: String { session?.username ?? "" }
    var balanceText: String { balance.map(NairaFormat.string) ?? "₦ --" }

    private init() {
        if let stored = KeychainManager.loadSession(), !stored.isExpired {
            session = stored
        } else {
            KeychainManager.deleteSession()
        }
        NotificationCenter.default.addObserver(forName: .slSessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleUnauthorized() }
        }
    }

    // MARK: - Sign in / out

    func login(_ login: String, password: String) async throws {
        let reply: LoginReply = try await SLAPIClient.shared.post(
            "/auth/login",
            body: ["login": login, "password": password, "device": "SL_Proxy iOS"],
            authenticated: false
        )
        let stored = KeychainManager.Session(token: reply.token, username: reply.username, expiresAt: reply.expiresAt)
        try KeychainManager.saveSession(stored)
        session = stored
        balance = reply.balance
        notice = nil
        showLogin = false
    }

    /// Revokes the token on the server (best effort) and forgets it locally.
    func logout() async {
        if isLoggedIn {
            struct Ok: Decodable { let ok: Bool? }
            let _: Ok? = try? await SLAPIClient.shared.post("/auth/logout", body: [:])
        }
        clearLocal()
    }

    /// A 401 from any call: the token is gone, ask the user to sign in again.
    func handleUnauthorized() {
        let hadSession = session != nil
        clearLocal()
        if hadSession {
            notice = "Your session ended. Sign in again."
            showLogin = true
        }
    }

    private func clearLocal() {
        KeychainManager.deleteSession()
        session = nil
        balance = nil
    }

    // MARK: - Balance

    func refreshBalance() async {
        guard isLoggedIn, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let reply: BalanceReply = try? await SLAPIClient.shared.get("/user/balance") {
            balance = reply.balance
        }
    }

    func updateBalance(_ value: Double?) {
        if let value { balance = value }
    }
}
