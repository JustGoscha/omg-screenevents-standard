import AVFoundation
import ReplayKit
import ScreenEventsKit
import UIKit

/// SE Recorder: starts the broadcast extension and shows what it measured; also has an in-app
/// listener that draws incoming events live (for the simulator, or Split View next to SE Source).
/// Launch arguments: -SEInAppListener (turn the in-app listener on).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = RecorderViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

/// Counts of what the in-app listener received, in a form the UI test can parse.
struct InAppCounts {
    var listener = "off"
    var sessions = 0
    var ended = 0
    var messages: [String: Int] = [:]
    var samples = 0
    var kinds: [String: Int] = [:]
    var phases: [String: Int] = [:]
    var display = "–"

    var text: String {
        func list(_ d: [String: Int]) -> String { d.isEmpty ? "none" : d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
        return """
        listener: \(listener) · sessions: \(sessions) · ended: \(ended)
        messages: \(list(messages))
        samples: \(samples) · kinds: \(list(kinds))
        phases: \(list(phases))
        display: \(display)
        """
    }
}

final class RecorderViewController: UIViewController {
    let overlay = OverlayView()
    let inAppLabel = UILabel()
    let broadcastLabel = UILabel()
    let inAppSwitch = UISwitch()
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
    var recorder: ScreenEventsRecorder?
    var counts = InAppCounts()
    let keepAlive = KeepAlive()
    var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        picker.preferredExtension = "app.omg.screenevents.recorder.broadcast"
        picker.showsMicrophoneButton = false
        let pickerLabel = UILabel()
        pickerLabel.text = "Start broadcast (system-wide recording via the extension)"
        pickerLabel.font = .preferredFont(forTextStyle: .subheadline)

        for l in [inAppLabel, broadcastLabel] {
            l.numberOfLines = 0
            l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        inAppLabel.accessibilityIdentifier = "inapp"
        broadcastLabel.accessibilityIdentifier = "broadcast"

        #if targetEnvironment(simulator)
        let defaultOn = true
        #else
        let defaultOn = false   // on a device the extension is the recorder; the in-app one would take port 47833
        #endif
        inAppSwitch.isOn = defaultOn || ProcessInfo.processInfo.arguments.contains("-SEInAppListener")
        inAppSwitch.addAction(UIAction { [unowned self] _ in setInApp(inAppSwitch.isOn) }, for: .valueChanged)
        let inAppTitle = UILabel()
        inAppTitle.text = "In-app listener (keeps running in background with silent audio)"
        inAppTitle.font = .preferredFont(forTextStyle: .subheadline)

        let share = UIButton(type: .system, primaryAction: UIAction(title: "Share last sidecar") { [unowned self] _ in shareSidecar() })

        let pickerRow = UIStackView(arrangedSubviews: [picker, pickerLabel, share]); pickerRow.spacing = 12; pickerRow.alignment = .center
        let inAppRow = UIStackView(arrangedSubviews: [inAppSwitch, inAppTitle]); inAppRow.spacing = 12; inAppRow.alignment = .center
        let h1 = UILabel(); h1.text = "Broadcast extension"; h1.font = .preferredFont(forTextStyle: .headline)
        let h2 = UILabel(); h2.text = "In-app listener"; h2.font = .preferredFont(forTextStyle: .headline)
        let stack = UIStackView(arrangedSubviews: [h1, pickerRow, broadcastLabel, h2, inAppRow, inAppLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading

        overlay.backgroundColor = .secondarySystemBackground
        for v in [stack, overlay] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            picker.widthAnchor.constraint(equalToConstant: 56), picker.heightAnchor.constraint(equalToConstant: 56),
            stack.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            overlay.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        setInApp(inAppSwitch.isOn)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func setInApp(_ on: Bool) {
        recorder?.stop()
        recorder = nil
        counts = InAppCounts()
        guard on else { keepAlive.stop(); refresh(); return }
        keepAlive.start()
        let rec = ScreenEventsRecorder(recorder: Peer(id: "app.omg.screenevents.recorder", name: "SE Recorder (in-app)", version: "1.0"))
        rec.onState = { [weak self] st in
            switch st {
            case .listening(let p): self?.counts.listener = "listening :\(p)"
            case .failed(let e): self?.counts.listener = "failed: \(e)"
            case .stopped: self?.counts.listener = "stopped"
            }
        }
        rec.onSessionStart = { [weak self] _ in self?.counts.sessions += 1 }
        rec.onSessionEnd = { [weak self] s in self?.counts.ended += 1; self?.overlay.cancelAll(s.id) }
        rec.onMessage = { [weak self] s, m in self?.received(m, s) }
        rec.start()
        recorder = rec
    }

    func received(_ m: Message, _ s: ScreenEventsRecorder.Session) {
        switch m {
        case .touch(let t):
            counts.messages["touch", default: 0] += 1
            counts.samples += t.samples.count
            counts.kinds[t.kind, default: 0] += 1
            counts.phases[t.phase, default: 0] += 1
            overlay.apply(t, session: s.id)
        case .display(let d):
            counts.messages["display", default: 0] += 1
            counts.display = "\(Int(d.screen.size[0]))×\(Int(d.screen.size[1]))@\(Int(d.screen.scale))x rot \(d.screen.rotation)"
            overlay.screenSize = CGSize(width: d.screen.size[0], height: d.screen.size[1])
        case .update: counts.messages["update", default: 0] += 1
        case .action(let a): counts.messages[a.name, default: 0] += 1; overlay.flash()
        case .privacy(let p): counts.messages["privacy-\(p.state)", default: 0] += 1
        case .hints: counts.messages["hints", default: 0] += 1
        case .unknown(let t): counts.messages["unknown-\(t)", default: 0] += 1
        default: break
        }
    }

    func refresh() {
        inAppLabel.text = counts.text
        broadcastLabel.text = BroadcastStats.load()?.summary ?? "no broadcast yet (App Group: \(BroadcastStats.directory == nil ? "unavailable" : "ok"))"
    }

    func shareSidecar() {
        guard let dir = BroadcastStats.directory, let name = BroadcastStats.load()?.sidecar else { return }
        let files = [dir.appendingPathComponent(name), dir.appendingPathComponent("stats.json")]
        let vc = UIActivityViewController(activityItems: files, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 80, width: 1, height: 1)
        present(vc, animated: true)
    }
}

/// Plays silence so the in-app listener keeps running while SE Source is in front (test only;
/// this is the "background listener" from SPEC.md §10's threat model).
final class KeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800) else { return }
        buf.frameLength = 4800
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        player.stop(); engine.stop()
        running = false
    }
}

/// Draws live contacts in the Source's fixed screen space, fitted into this view (SPEC.md §8).
final class OverlayView: UIView {
    struct Contact { var kind: String; var phase: String; var last: Sample; var trail: [CGPoint]; var endedAt: Date? }
    var screenSize = CGSize(width: 1024, height: 1366) { didSet { setNeedsDisplay() } }
    private var contacts: [String: Contact] = [:]
    private var flashUntil = Date.distantPast
    private var link: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let now = Date()
        contacts = contacts.filter { $0.value.endedAt.map { now.timeIntervalSince($0) < 0.6 } ?? true }
        setNeedsDisplay()
    }

    func apply(_ t: Touch, session: UUID) {
        let key = "\(session)/\(t.id)"
        guard let last = t.samples.last else { return }
        var c = contacts[key] ?? Contact(kind: t.kind, phase: t.phase, last: last, trail: [], endedAt: nil)
        c.phase = t.phase
        c.last = last
        c.trail.append(contentsOf: t.samples.map { CGPoint(x: $0.x, y: $0.y) })
        if c.trail.count > 400 { c.trail.removeFirst(c.trail.count - 400) }
        if t.isEnd { c.endedAt = Date() }
        contacts[key] = c
    }

    func cancelAll(_ session: UUID) {
        for (k, var c) in contacts where k.hasPrefix(session.uuidString) && c.endedAt == nil {
            c.endedAt = Date(); contacts[k] = c
        }
    }

    func flash() { flashUntil = Date().addingTimeInterval(0.3) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // aspect-fit the source screen (native orientation) into the view
        let s = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
        let ox = (bounds.width - screenSize.width * s) / 2, oy = (bounds.height - screenSize.height * s) / 2
        func v(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        UIColor.separator.setStroke()
        UIBezierPath(rect: CGRect(x: ox, y: oy, width: screenSize.width * s, height: screenSize.height * s)).stroke()
        if Date() < flashUntil {
            UIColor.systemYellow.withAlphaComponent(0.3).setFill(); ctx.fill(bounds)
        }
        for c in contacts.values {
            let fade: CGFloat = c.endedAt.map { 1 - CGFloat(Date().timeIntervalSince($0) / 0.6) } ?? 1
            let p = v(c.last.x, c.last.y)
            let color: UIColor = c.kind == "pencil" ? .systemBlue : c.kind == "pointer" ? .systemGreen : .systemOrange
            if c.trail.count > 1 {
                let path = UIBezierPath()
                path.move(to: v(c.trail[0].x, c.trail[0].y))
                for q in c.trail.dropFirst() { path.addLine(to: v(q.x, q.y)) }
                color.withAlphaComponent(0.35 * fade).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            if c.phase.hasPrefix("hover") {
                let r = 10 + 30 * CGFloat(c.last.z ?? 0.5)
                color.withAlphaComponent(0.7 * fade).setStroke()
                UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).stroke()
            } else if c.kind == "pencil" {
                // barrel from the tip along azimuth; projected length shrinks as the Pencil stands up (SPEC.md §8.3)
                if let az = c.last.azimuth, let alt = c.last.altitude {
                    let len = 160 * s * CGFloat(cos(alt))
                    let end = CGPoint(x: p.x + CGFloat(cos(az)) * len, y: p.y + CGFloat(sin(az)) * len)
                    let barrel = UIBezierPath(); barrel.move(to: p); barrel.addLine(to: end)
                    barrel.lineWidth = 10 * s + 4; barrel.lineCapStyle = .round
                    UIColor.label.withAlphaComponent(0.25 * fade).setStroke(); barrel.stroke()
                }
                let r = 3 + 8 * CGFloat(c.last.force ?? 0.3)
                color.withAlphaComponent(fade).setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            } else {
                let r = max(8, CGFloat(c.last.radius ?? 20) * s)
                color.withAlphaComponent(0.5 * fade).setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }
}
