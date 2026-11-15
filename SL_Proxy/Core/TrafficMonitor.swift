import Combine
import Foundation

struct TrafficSample: Identifiable {
    let id: Int
    let down: Double
    let up: Double
}

/// Bytes moved during one Clash API traffic tick (one second).
struct TrafficDelta: Equatable {
    let down: Int64
    let up: Int64
}

/// Streams live throughput from the sing-box Clash API while the tunnel runs.
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var downloadSpeed: Int64 = 0
    @Published private(set) var uploadSpeed: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = 0
    @Published private(set) var uploadTotal: Int64 = 0
    @Published private(set) var history: [TrafficSample]

    /// One event per traffic tick, for consumers that accumulate bytes (`DataBudgetTracker`).
    let samples = PassthroughSubject<TrafficDelta, Never>()

    private static let historyLength = 60
    private var task: Task<Void, Never>?
    private var counter = 0

    private struct ClashTraffic: Decodable {
        let up: Int64
        let down: Int64
    }

    init() {
        history = (0..<TrafficMonitor.historyLength).map { TrafficSample(id: $0, down: 0, up: 0) }
        counter = TrafficMonitor.historyLength
    }

    func start() {
        guard task == nil else { return }
        downloadTotal = 0
        uploadTotal = 0
        task = Task { [weak self] in
            await self?.stream()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        downloadSpeed = 0
        uploadSpeed = 0
        push(down: 0, up: 0)
    }

    var downloadSpeedText: String { TrafficMonitor.rate(downloadSpeed) }
    var uploadSpeedText: String { TrafficMonitor.rate(uploadSpeed) }
    var downloadTotalText: String { TrafficMonitor.bytes(downloadTotal) }
    var uploadTotalText: String { TrafficMonitor.bytes(uploadTotal) }

    static func rate(_ value: Int64) -> String { bytes(value) + "/s" }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    // MARK: - Private

    private func stream() async {
        guard let url = URL(string: "http://\(AppGroup.clashAPIAddress)/traffic") else { return }
        while !Task.isCancelled {
            do {
                let (bytes, _) = try await URLSession.shared.bytes(from: url)
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard let data = line.data(using: .utf8),
                          let sample = try? JSONDecoder().decode(ClashTraffic.self, from: data) else { continue }
                    apply(sample)
                }
            } catch {
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func apply(_ sample: ClashTraffic) {
        downloadSpeed = sample.down
        uploadSpeed = sample.up
        downloadTotal += sample.down
        uploadTotal += sample.up
        push(down: Double(sample.down), up: Double(sample.up))
        samples.send(TrafficDelta(down: sample.down, up: sample.up))
    }

    private func push(down: Double, up: Double) {
        history.append(TrafficSample(id: counter, down: down, up: up))
        counter += 1
        if history.count > TrafficMonitor.historyLength {
            history.removeFirst(history.count - TrafficMonitor.historyLength)
        }
    }
}
