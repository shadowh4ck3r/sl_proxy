import Foundation

/// The signed-in SailorsLoot account: Keychain-backed token, wallet balance and the login prompt.
@MainActor
final class SLAccountStore: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var username: String?
    @Published private(set) var balance: Double?
    @Published private(set) var isBusy = false
    /// Set when the server answered 401 (or there is no token): views present the login screen.
    @Published var needsLogin = false
    @Published var errorMessage: String?

    private let api = SLAPIClient.shared

    init() {
        isLoggedIn = KeychainManager.get(KeychainManager.Key.token) != nil
        username = KeychainManager.get(KeychainManager.Key.username)
    }

    /// "₦ 514.03"
    var balanceText: String {
        guard let balance else { return "\u{20A6} --" }
        return "\u{20A6} " + Self.format(balance)
    }

    static func format(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    func login(identifier: String, password: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let reply: SLLoginReply = try await api.post(
                "auth/login",
                body: ["username": identifier, "password": password, "device": "SL_Proxy iOS"],
                authenticated: false
            )
            KeychainManager.set(reply.token, for: KeychainManager.Key.token)
            KeychainManager.set(reply.username, for: KeychainManager.Key.username)
            username = reply.username
            balance = reply.balance
            isLoggedIn = true
            needsLogin = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Revokes the token on the server (best effort) and wipes it from the Keychain.
    func logout() async {
        let _: SLEmptyReply? = try? await api.post("auth/logout", body: [:])
        clearSession()
    }

    func refreshBalance() async {
        guard isLoggedIn else { return }
        do {
            let reply: SLBalanceReply = try await api.get("user/balance")
            balance = reply.balance
            username = reply.username
        } catch {
            handle(error)
        }
    }

    func updateBalance(_ value: Double) {
        balance = value
    }

    /// Call from every API failure: a 401 drops the dead token and prompts the user to log in again.
    func handle(_ error: Error) {
        if case SLAPIError.unauthorized = error {
            clearSession()
            needsLogin = true
            errorMessage = SLAPIError.unauthorized.errorDescription
        }
    }

    private func clearSession() {
        KeychainManager.delete(KeychainManager.Key.token)
        KeychainManager.delete(KeychainManager.Key.username)
        isLoggedIn = false
        username = nil
        balance = nil
    }
}

struct SLEmptyReply: Decodable {}
