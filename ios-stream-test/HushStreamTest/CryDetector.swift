import Foundation
import TensorFlowLite

/// Turns the NotePin S live PCM stream into YAMNet cry scores and cry episodes.
///
/// Input: the `blePcmData` chunks from PlaudDeviceAgent (640 bytes = 320 Int16 samples,
/// 16 kHz mono, about 20 ms each). YAMNet needs 15,600 float samples (0.975 s) per
/// inference, so chunks are collected into a sliding window and scored every 0.48 s.
///
/// Privacy: audio is only kept while an episode is open (plus the pre-roll).
/// Everything else is overwritten in memory and never written to disk.
final class CryDetector {

    struct Config {
        var sampleRate = 16_000
        var windowSamples = 15_600          // YAMNet's fixed input length
        var hopSamples = 7_680              // 0.48 s, YAMNet's native hop
        var cryLabels = ["Baby cry, infant cry", "Crying, sobbing"]
        var startThreshold: Float = 0.35    // smoothed score that opens an episode
        var stopThreshold: Float = 0.20     // score that keeps an episode alive
        var smoothingFrames = 3             // moving average over ~1.4 s
        var endAfterSeconds: Double = 8     // quiet time before an episode closes
        var preRollSeconds: Double = 10     // audio kept from before the cry started
        var maxEpisodeSeconds: Double = 180 // long cries are split into several clips
    }

    struct Frame {
        let streamSeconds: Double
        let cryScore: Float
        let smoothedScore: Float
        let topLabel: String
        let topScore: Float
        let inferenceMs: Double
        let inEpisode: Bool
    }

    struct Episode {
        let id = UUID()
        let startedAt: Date
        let startStreamSeconds: Double
        var endedAt: Date?
        var peakScore: Float
        var clipURL: URL?
        var durationSeconds: Double { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    }

    enum DetectorError: Error {
        case cryLabelsNotFound
        case unexpectedInputShape([Int])
    }

    // Callbacks are delivered on the main queue.
    var onFrame: ((Frame) -> Void)?
    var onEpisodeStart: ((Episode) -> Void)?
    var onEpisodeEnd: ((Episode) -> Void)?
    var onStreamGap: ((_ missingMs: Int) -> Void)?

    let config: Config
    let labels: [String]
    private let cryIndices: [Int]
    private let interpreter: Interpreter
    private let queue = DispatchQueue(label: "hush.crydetector", qos: .userInitiated)
    private let clipsDirectory: URL

    private var window: [Float] = []
    private var samplesSinceHop = 0
    private var preRoll: RingBuffer
    private var clip: [Int16] = []
    private var recentScores: [Float] = []
    private var episode: Episode?
    private var lastLoudSeconds: Double = 0
    private var streamSeconds: Double = 0
    private var lastChunkMillsec: Int?
    private var lastChunkMs = 20

    init(modelURL: URL, classMapURL: URL, clipsDirectory: URL, config: Config = Config()) throws {
        self.config = config
        self.clipsDirectory = clipsDirectory
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)

        var options = Interpreter.Options()
        options.threadCount = 2
        interpreter = try Interpreter(modelPath: modelURL.path, options: options)
        try interpreter.allocateTensors()
        let shape = try interpreter.input(at: 0).shape.dimensions
        guard shape.reduce(1, *) == config.windowSamples else { throw DetectorError.unexpectedInputShape(shape) }

        let names = try Self.loadLabels(from: classMapURL)
        let indices = config.cryLabels.compactMap { names.firstIndex(of: $0) }
        guard !indices.isEmpty else { throw DetectorError.cryLabelsNotFound }
        labels = names
        cryIndices = indices

        preRoll = RingBuffer(capacity: Int(config.preRollSeconds) * config.sampleRate)
        window.reserveCapacity(config.windowSamples + 1_024)
    }

    /// Call from `blePcmData(sessionId:millsec:pcmData:isMusic:)`. Safe from any thread.
    func ingest(pcm: Data, millsec: Int) {
        queue.async { [weak self] in self?.process(pcm: pcm, millsec: millsec) }
    }

    /// Closes any open episode (for example when recording stops).
    func flush() {
        queue.async { [weak self] in self?.finishEpisode() }
    }

    // MARK: - Pipeline

    private func process(pcm: Data, millsec: Int) {
        let samples = Self.int16Samples(from: pcm)
        guard !samples.isEmpty else { return }
        let chunkMs = samples.count * 1_000 / config.sampleRate

        // `millsec` is the device's position in the recording. A jump bigger than two
        // chunks means BLE dropped audio. Worth measuring before trusting the detector.
        if let last = lastChunkMillsec {
            let missing = millsec - last - lastChunkMs
            if missing > 2 * chunkMs { DispatchQueue.main.async { self.onStreamGap?(missing) } }
        }
        lastChunkMillsec = millsec
        lastChunkMs = chunkMs

        streamSeconds += Double(samples.count) / Double(config.sampleRate)
        preRoll.append(samples)
        if episode != nil { clip.append(contentsOf: samples) }

        window.append(contentsOf: samples.map { Float($0) / 32_768 })
        if window.count > config.windowSamples { window.removeFirst(window.count - config.windowSamples) }
        samplesSinceHop += samples.count
        guard window.count == config.windowSamples, samplesSinceHop >= config.hopSamples else { return }
        samplesSinceHop = 0

        do { try classifyWindow() } catch { print("[CryDetector] inference failed: \(error)") }
    }

    private func classifyWindow() throws {
        let started = CFAbsoluteTimeGetCurrent()
        let input = window.withUnsafeBufferPointer { Data(buffer: $0) }
        try interpreter.copy(input, toInputAt: 0)
        try interpreter.invoke()
        let output = try interpreter.output(at: 0)
        let scores: [Float] = output.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let inferenceMs = (CFAbsoluteTimeGetCurrent() - started) * 1_000

        let cryScore = cryIndices.map { scores[$0] }.max() ?? 0
        recentScores.append(cryScore)
        if recentScores.count > config.smoothingFrames { recentScores.removeFirst() }
        let smoothed = recentScores.reduce(0, +) / Float(recentScores.count)
        let top = scores.indices.max { scores[$0] < scores[$1] } ?? 0

        updateEpisode(smoothed: smoothed)

        let frame = Frame(streamSeconds: streamSeconds, cryScore: cryScore, smoothedScore: smoothed,
                          topLabel: labels[top], topScore: scores[top],
                          inferenceMs: inferenceMs, inEpisode: episode != nil)
        DispatchQueue.main.async { self.onFrame?(frame) }
    }

    private func updateEpisode(smoothed: Float) {
        if var open = episode {
            if smoothed >= config.stopThreshold {
                lastLoudSeconds = streamSeconds
                open.peakScore = max(open.peakScore, smoothed)
                episode = open
            }
            let quietFor = streamSeconds - lastLoudSeconds
            let runningFor = streamSeconds - open.startStreamSeconds
            if quietFor >= config.endAfterSeconds || runningFor >= config.maxEpisodeSeconds {
                finishEpisode()
                // A cry that is still going after the split starts a fresh episode straight away.
                if smoothed >= config.startThreshold { startEpisode(score: smoothed) }
            }
        } else if smoothed >= config.startThreshold {
            startEpisode(score: smoothed)
        }
    }

    private func startEpisode(score: Float) {
        clip = preRoll.snapshot()
        lastLoudSeconds = streamSeconds
        let opened = Episode(startedAt: Date(), startStreamSeconds: streamSeconds, peakScore: score)
        episode = opened
        DispatchQueue.main.async { self.onEpisodeStart?(opened) }
    }

    private func finishEpisode() {
        guard var closed = episode else { return }
        closed.endedAt = Date()
        let url = clipsDirectory.appendingPathComponent("cry-\(Self.fileStamp(closed.startedAt)).wav")
        do {
            try WavWriter.write(samples: clip, sampleRate: config.sampleRate, to: url)
            closed.clipURL = url
        } catch {
            print("[CryDetector] could not save clip: \(error)")
        }
        episode = nil
        clip = []
        DispatchQueue.main.async { self.onEpisodeEnd?(closed) }
    }

    // MARK: - Helpers

    static func int16Samples(from data: Data) -> [Int16] {
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            (0..<count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }

    /// Parses yamnet_class_map.csv (index,mid,display_name; names with commas are quoted).
    static func loadLabels(from url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).dropFirst().map { line in
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return String(line) }
            return parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

/// Fixed-size buffer holding the last N samples, used for the pre-roll.
struct RingBuffer {
    private var storage: [Int16]
    private var head = 0
    private var filled = false

    init(capacity: Int) { storage = Array(repeating: 0, count: max(capacity, 1)) }

    mutating func append(_ samples: [Int16]) {
        for s in samples {
            storage[head] = s
            head = (head + 1) % storage.count
            if head == 0 { filled = true }
        }
    }

    func snapshot() -> [Int16] {
        filled ? Array(storage[head...] + storage[..<head]) : Array(storage[..<head])
    }
}

enum WavWriter {
    /// Writes 16-bit mono PCM with a standard 44-byte WAV header.
    static func write(samples: [Int16], sampleRate: Int, to url: URL) throws {
        let dataBytes = UInt32(samples.count * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBufferPointer { buf in
            buf.forEach { s in withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        try d.write(to: url, options: .atomic)
    }
}
