import SwiftUI

extension String {
    /// Hides the middle of a credential-like value: the first and last four characters stay, the
    /// rest becomes dots ("global.example.com:20000" shows as "glob••••0000"). Values of eight
    /// characters or fewer are hidden completely. Matches how V2Box masks server addresses.
    var masked: String {
        guard count > 8 else { return String(repeating: "•", count: Swift.max(count, 4)) }
        return String(prefix(4)) + "••••" + String(suffix(4))
    }
}
