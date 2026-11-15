import AVFoundation
import Combine
import UIKit

/// Keeps the app process alive while the user-space engine runs.
///
/// iOS suspends a normal app seconds after it leaves the foreground, which would freeze the
/// loopback proxy listener (127.0.0.1:20080 by default). Two mechanisms together prevent that:
///  1. A looping, code-generated silent WAV played through a `.playback` audio session that mixes
///     with other audio. iOS treats the app as an active audio player and does not suspend it.
///  2. A `beginBackgroundTask` assertion. With the private `unboundedTaskCompletion` background
///     mode (honoured on TrollStore installs, see project.yml) it is unlimited; elsewhere iOS
///     expires it after roughly 30 s and the audio session carries on alone.
/// `stop()` tears everything down so a disconnected app costs no battery.
@MainActor
final class BackgroundKeepAlive: ObservableObject {
    @Published private(set) var isActive = false
    /// Last audio session error, if any (surfaced in the engine log).
    @Published private(set) var lastProblem: String?

    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isActive else { return }
        isActive = true
        lastProblem = nil
        beginBackgroundTask()
        startAudio()
        observe()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
    }

    // MARK: - Audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let player = try AVAudioPlayer(data: Self.silentWAV(), fileTypeHint: AVFileType.wav.rawValue)
                player.numberOfLoops = -1
                player.volume = 0
                player.prepareToPlay()
                self.player = player
            }
            if let player, !player.isPlaying {
                player.play()
            }
            lastProblem = nil
        } catch {
            lastProblem = error.localizedDescription
        }
    }

    /// Re-arms the session and the background task after anything that could have stopped them.
    private func resumeIfNeeded(recreatePlayer: Bool = false) {
        guard isActive else { return }
        if recreatePlayer {
            player?.stop()
            player = nil
        }
        startAudio()
        if backgroundTask == .invalid {
            beginBackgroundTask()
        }
    }

    private func observe() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.resumeIfNeeded() }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded(recreatePlayer: true) }
        })

        for name in [
            AVAudioSession.routeChangeNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeIfNeeded() }
            })
        }

        // A fresh task on every background transition gives another grace period on systems that
        // ignore unboundedTaskCompletion.
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.beginBackgroundTask()
                self.startAudio()
            }
        })
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SL_Proxy.engine") { [weak self] in
            // Without unboundedTaskCompletion iOS calls this after ~30 s. The audio session keeps
            // the process alive from here; just release the expired assertion.
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Silent track

    /// One second of 16-bit mono PCM silence wrapped in a RIFF/WAVE header. Generated in code so
    /// the bundle needs no audio asset.
    static func silentWAV(seconds: Double = 1, sampleRate: Int = 44_100) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerFrame = channels * bitsPerSample / 8
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataSize = frameCount * bytesPerFrame

        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                                   // fmt chunk size
        append(UInt16(1))                                    // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerFrame))           // byte rate
        append(UInt16(bytesPerFrame))                        // block align
        append(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
