import SwiftUI

/// Health bucket for a measured latency. One place decides the thresholds, the colour and the
/// wording, so the Configs list, the Home server card, the server picker and the Ping chip always
/// agree.
///
/// `ProxyNode.latencyMs` is `nil` before the first test and `-1` when the test failed.
enum LatencyStatus: Equatable {
    case untested
    case testing
    /// Under 150 ms.
    case fast
    /// 150 to 299 ms.
    case good
    /// 300 to 599 ms.
    case fair
    /// 600 ms and above.
    case slow
    case timeout

    init(latency: Int?, isTesting: Bool = false) {
        if isTesting {
            self = .testing
            return
        }
        guard let latency else {
            self = .untested
            return
        }
        switch latency {
        case ..<0: self = .timeout
        case ..<150: self = .fast
        case ..<300: self = .good
        case ..<600: self = .fair
        default: self = .slow
        }
    }

    var title: String {
        switch self {
        case .untested: return "Not tested"
        case .testing: return "Testing"
        case .fast: return "Fast"
        case .good: return "Good"
        case .fair: return "Fair"
        case .slow: return "Slow"
        case .timeout: return "Timeout"
        }
    }

    var color: Color {
        switch self {
        case .untested, .testing: return Color.secondary
        case .fast: return Color.green
        case .good: return Color.teal
        case .fair: return Brand.gold
        case .slow: return Color.orange
        case .timeout: return Color.red
        }
    }
}
