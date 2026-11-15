import Foundation

/// Thread-safe ring buffer of sing-box log lines for the in-app engine, served to the Logs tab.
///
/// Every line is also appended to `engine.log` in Application Support so the tail of the previous
/// run survives an app restart (it is replayed into the buffer on the next launch) and can be
/// attached to start errors. Mirrors `TunnelLogBuffer` from the system VPN build on `main`.
final class EngineLogBuffer {
    static let shared = EngineLogBuffer()

    private let lock = NSLock()
    private var lines: [TunnelLogLine] = []
    private var nextIndex = 0
    private let capacity = 600
    private let replayCount = 40
    private var handle: FileHandle?

    private init() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let directory = root.appendingPathComponent("SL_Proxy", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("engine.log", isDirectory: false)

        replayPreviousRun(from: url)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        store(message)
        if let data = "\(Self.formatter.string(from: Date())) \(message)\n".data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    /// Lines with an index of `index` or later, plus the index the caller should ask for next.
    func lines(after index: Int) -> (lines: [TunnelLogLine], next: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (lines.filter { $0.id >= index }, nextIndex)
    }

    /// The most recent `count` messages, oldest first.
    func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).map(\.message)
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func store(_ message: String) {
        lines.append(TunnelLogLine(id: nextIndex, date: Date(), message: message))
        nextIndex += 1
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// Loads the tail of the previous run into the buffer and shrinks the file to that tail so it
    /// stays bounded across runs.
    private func replayPreviousRun(from url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        let previous = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(replayCount))
        if !previous.isEmpty {
            store("--- previous run (\(previous.count) lines) ---")
            for line in previous {
                store("[prev] \(line)")
            }
            store("--- current run ---")
        }
        let kept = previous.isEmpty ? "" : previous.joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
