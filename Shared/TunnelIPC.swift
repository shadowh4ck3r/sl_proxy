import Foundation

/// Request sent from the app to the tunnel extension through `sendProviderMessage`.
enum TunnelRequest: Codable {
    /// Current running state and the last start error, if any.
    case status
    /// Log lines with an index greater than or equal to `after`.
    case logs(after: Int)
    /// Drops the buffered log lines.
    case clearLogs
}

struct TunnelLogLine: Codable, Identifiable, Hashable {
    let id: Int
    let date: Date
    let message: String
}

/// Reply returned by the tunnel extension for every `TunnelRequest`.
struct TunnelReply: Codable {
    var running: Bool
    var startedAt: Date?
    var lastError: String?
    var logs: [TunnelLogLine] = []
    var nextLogIndex: Int = 0
    /// Whether the extension process can see the App Group container.
    var appGroupAvailable: Bool? = nil
    /// Where the running configuration came from ("start options", "VPN profile", "App Group file").
    var configSource: String? = nil
}
