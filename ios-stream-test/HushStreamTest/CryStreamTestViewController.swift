import UIKit

/// Field-test screen: NotePin S live PCM → YAMNet, with live scores, stream health,
/// ground-truth buttons and CSV export. Opened from the "Cry test" pill on the main screen.
final class CryStreamTestViewController: UIViewController {

    private let tap = HushAudioTap.shared
    private let scoreLabel = UILabel()
    private let stateLabel = UILabel()
    private let statsLabel = UILabel()
    private let graph = ScoreGraphView()
    private let log = UITextView()
    private let startButton = UIButton(type: .system)
    private let cryingButton = UIButton(type: .system)
    private let falseAlarmButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private var statsTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Cry stream test"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        scoreLabel.text = "0.00"
        stateLabel.font = .preferredFont(forTextStyle: .headline)
        stateLabel.text = "Not running"
        statsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statsLabel.numberOfLines = 0
        statsLabel.textColor = .secondaryLabel
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.isEditable = false
        log.backgroundColor = .secondarySystemBackground
        log.layer.cornerRadius = 10

        style(startButton, "Start test", .systemIndigo, #selector(toggle))
        style(cryingButton, "Baby is crying", .systemOrange, #selector(markCrying))
        style(falseAlarmButton, "False alarm", .systemGray, #selector(markFalseAlarm))
        style(exportButton, "Export CSV", .systemTeal, #selector(exportCSV))

        let marks = UIStackView(arrangedSubviews: [cryingButton, falseAlarmButton])
        marks.distribution = .fillEqually
        marks.spacing = 8
        let stack = UIStackView(arrangedSubviews: [stateLabel, scoreLabel, graph, statsLabel, startButton, marks, exportButton, log])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            graph.heightAnchor.constraint(equalToConstant: 110),
            log.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        tap.onFrame = { [weak self] f in self?.show(frame: f) }
        tap.onEpisodeStart = { [weak self] e in self?.append("CRY START  \(Self.time(e.startedAt))  score \(String(format: "%.2f", e.peakScore))") }
        tap.onEpisodeEnd = { [weak self] e in
            self?.append("CRY END    \(Self.time(e.endedAt ?? Date()))  \(Int(e.durationSeconds))s  peak \(String(format: "%.2f", e.peakScore))  \(e.clipURL?.lastPathComponent ?? "no clip")")
        }
        tap.onGap = { [weak self] ms in self?.append("GAP        \(ms) ms of audio missing") }
        updateButtons()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !tap.isRunning { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Actions

    @objc private func toggle() {
        if tap.isRunning {
            tap.stop()
            RecordingManager.shared.stopRecord()
            statsTimer?.invalidate()
            UIApplication.shared.isIdleTimerDisabled = false
            stateLabel.text = "Stopped"
            append("SESSION    stopped")
        } else {
            do {
                try tap.start()
                // bleRecordStart in DeviceManager calls syncFile(...), which turns on the PCM stream.
                RecordingManager.shared.startRecord()
                // Overnight tests: keep the phone on a charger with the screen awake so iOS doesn't suspend BLE.
                UIApplication.shared.isIdleTimerDisabled = true
                stateLabel.text = "Listening. Waiting for audio from the NotePin S…"
                append("SESSION    started, log: \(tap.csvURL?.lastPathComponent ?? "-")")
                statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.showStats() }
            } catch {
                stateLabel.text = error.localizedDescription
            }
        }
        updateButtons()
    }

    @objc private func markCrying() { tap.mark(.cryingNow); append("MARK       parent: baby is crying") }
    @objc private func markFalseAlarm() { tap.mark(.falseAlarm); append("MARK       parent: false alarm") }

    @objc private func exportCSV() {
        guard let url = tap.csvURL else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = exportButton
        present(sheet, animated: true)
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: - Display

    private func show(frame f: CryDetector.Frame) {
        scoreLabel.text = String(format: "%.2f", f.smoothedScore)
        scoreLabel.textColor = f.inEpisode ? .systemOrange : .label
        stateLabel.text = f.inEpisode ? "Crying detected" : "Listening · top sound: \(f.topLabel)"
        graph.push(f.smoothedScore, crying: f.inEpisode)
    }

    private func showStats() {
        let s = tap.stats
        let audioSeconds = Double(s.bytes) / 32_000  // 16 kHz × 2 bytes
        statsLabel.text = """
        chunks \(s.chunks)   audio \(String(format: "%.0f", audioSeconds)) s   frames \(s.frames)
        gaps \(s.gaps) (\(s.missingMs) ms lost)   inference \(String(format: "%.1f", s.avgInferenceMs)) ms avg
        episodes \(s.episodes)
        """
        if s.chunks == 0 { stateLabel.text = "No audio yet. Is the NotePin S connected and recording?" }
    }

    private func updateButtons() {
        startButton.setTitle(tap.isRunning ? "Stop test" : "Start test", for: .normal)
        [cryingButton, falseAlarmButton].forEach { $0.isEnabled = tap.isRunning }
        exportButton.isEnabled = tap.csvURL != nil
    }

    private func append(_ line: String) {
        log.text = line + "\n" + (log.text ?? "")
    }

    private func style(_ b: UIButton, _ title: String, _ color: UIColor, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        b.backgroundColor = color.withAlphaComponent(0.15)
        b.tintColor = color
        b.layer.cornerRadius = 12
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// Rolling chart of smoothed cry scores with the start and stop thresholds drawn in.
final class ScoreGraphView: UIView {
    private var values: [(Float, Bool)] = []
    private let capacity = 150  // ~72 s at one frame every 0.48 s
    var startThreshold: Float = CryDetector.Config().startThreshold
    var stopThreshold: Float = CryDetector.Config().stopThreshold

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func push(_ v: Float, crying: Bool) {
        values.append((v, crying))
        if values.count > capacity { values.removeFirst() }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = rect.width / CGFloat(capacity)
        for (i, (v, crying)) in values.enumerated() {
            let h = rect.height * CGFloat(min(max(v, 0), 1))
            (crying ? UIColor.systemOrange : UIColor.systemIndigo).setFill()
            ctx.fill(CGRect(x: CGFloat(i) * w, y: rect.height - h, width: max(w - 1, 1), height: h))
        }
        for (t, color) in [(startThreshold, UIColor.systemOrange), (stopThreshold, UIColor.systemGray)] {
            let y = rect.height * (1 - CGFloat(t))
            color.setStroke()
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: rect.width, y: y))
            line.setLineDash([4, 4], count: 2, phase: 0)
            line.stroke()
        }
    }
}

/// Adds a small "Cry test" pill to the template app's main screen.
enum CryStreamTestLauncher {
    static func install(on host: UIViewController) {
        let pill = UIButton(type: .system)
        pill.setTitle("Cry test", for: .normal)
        pill.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        pill.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.15)
        pill.tintColor = .systemIndigo
        pill.layer.cornerRadius = 16
        pill.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addAction(UIAction { [weak host] _ in
            let nav = UINavigationController(rootViewController: CryStreamTestViewController())
            nav.modalPresentationStyle = .fullScreen
            host?.present(nav, animated: true)
        }, for: .touchUpInside)
        host.view.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -16),
        ])
    }
}
