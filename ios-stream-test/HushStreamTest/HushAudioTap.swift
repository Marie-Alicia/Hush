import Foundation

/// Single entry point for NotePin S PCM inside the Plaud template app.
///
/// DeviceManager.blePcmData forwards every chunk here (one line added by setup.sh).
/// When a test session is running, chunks go to the CryDetector and every YAMNet frame
/// is logged to a CSV you can export and compare against what really happened.
final class HushAudioTap {

    static let shared = HushAudioTap()

    struct Stats {
        var chunks = 0
        var bytes = 0
        var gaps = 0
        var missingMs = 0
        var frames = 0
        var episodes = 0
        var totalInferenceMs = 0.0
        var avgInferenceMs: Double { frames == 0 ? 0 : totalInferenceMs / Double(frames) }
    }

    enum Marker: String {
        case cryingNow = "parent_says_crying"
        case falseAlarm = "parent_says_false_alarm"
    }

    private(set) var detector: CryDetector?
    private(set) var stats = Stats()
    private(set) var isRunning = false
    private(set) var csvURL: URL?
    private var csv: FileHandle?
    private let lock = NSLock()
    private var pendingMarker: Marker?

    var onFrame: ((CryDetector.Frame) -> Void)?
    var onEpisodeStart: ((CryDetector.Episode) -> Void)?
    var onEpisodeEnd: ((CryDetector.Episode) -> Void)?
    var onGap: ((Int) -> Void)?

    static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hush", isDirectory: true)
    }

    private init() {}

    // MARK: - Session

    func start(config: CryDetector.Config = CryDetector.Config()) throws {
        guard !isRunning else { return }
        guard let model = Bundle.main.url(forResource: "yamnet", withExtension: "tflite"),
              let classMap = Bundle.main.url(forResource: "yamnet_class_map", withExtension: "csv") else {
            throw NSError(domain: "Hush", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "yamnet.tflite or yamnet_class_map.csv is missing from the app bundle. Run setup.sh again."])
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sessionDir = Self.baseDirectory.appendingPathComponent("sessions/\(stamp)", isDirectory: true)
        let d = try CryDetector(modelURL: model, classMapURL: classMap,
                                clipsDirectory: sessionDir.appendingPathComponent("cries"), config: config)

        let url = sessionDir.appendingPathComponent("frames.csv")
        FileManager.default.createFile(atPath: url.path, contents:
            Data("wall_time,stream_s,cry_score,smoothed,top_label,top_score,inference_ms,in_episode,marker\n".utf8))
        csv = try FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
        csvURL = url

        d.onFrame = { [weak self] f in self?.log(frame: f); self?.onFrame?(f) }
        d.onEpisodeStart = { [weak self] e in self?.onEpisodeStart?(e) }
        d.onEpisodeEnd = { [weak self] e in self?.stats.episodes += 1; self?.onEpisodeEnd?(e) }
        d.onStreamGap = { [weak self] ms in
            self?.stats.gaps += 1
            self?.stats.missingMs += ms
            self?.onGap?(ms)
        }
        lock.lock(); detector = d; stats = Stats(); isRunning = true; lock.unlock()
    }

    func stop() {
        lock.lock(); let d = detector; detector = nil; isRunning = false; lock.unlock()
        d?.flush()
        // Give the detector queue a moment to write the last clip before closing the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.csv?.closeFile()
            self?.csv = nil
        }
    }

    /// Ground truth from the parent, written onto the next frame in the CSV.
    func mark(_ marker: Marker) { pendingMarker = marker }

    // MARK: - PCM in (called from DeviceManager.blePcmData, BLE thread)

    func ingest(sessionId: Int, millsec: Int, pcm: Data) {
        lock.lock(); let d = detector; lock.unlock()
        guard let d else { return }
        DispatchQueue.main.async { self.stats.chunks += 1; self.stats.bytes += pcm.count }
        d.ingest(pcm: pcm, millsec: millsec)
    }

    // MARK: - CSV

    private func log(frame f: CryDetector.Frame) {
        stats.frames += 1
        stats.totalInferenceMs += f.inferenceMs
        let marker = pendingMarker?.rawValue ?? ""
        pendingMarker = nil
        let label = f.topLabel.replacingOccurrences(of: "\"", with: "'")
        let line = String(format: "%@,%.2f,%.4f,%.4f,\"%@\",%.4f,%.1f,%d,%@\n",
                          ISO8601DateFormatter().string(from: Date()), f.streamSeconds, f.cryScore,
                          f.smoothedScore, label, f.topScore, f.inferenceMs, f.inEpisode ? 1 : 0, marker)
        csv?.write(Data(line.utf8))
    }
}
