import ScreenEventsKit
import UIKit

/// SE Source: a drawing pad that sends its input with ScreenEvents.
/// Launch arguments: -SEForceCapture (send even when the screen isn't captured; the simulator never is).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = ScreenEventsWindow(frame: UIScreen.main.bounds)
        let capture = ScreenEventsTouchCapture(window: w, source: Peer(id: "app.omg.screenevents.source", name: "SE Source", version: "1.0", pid: Int(getpid())))
        w.capture = capture
        capture.ignoreCaptureState = ProcessInfo.processInfo.arguments.contains("-SEForceCapture")
        capture.userEnabled = true
        w.rootViewController = SourceViewController(capture: capture)
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

final class SourceViewController: UIViewController, UITextFieldDelegate {
    let capture: ScreenEventsTouchCapture
    let canvas = CanvasView()
    let status = UILabel()
    let share = UISwitch()
    let force = UISwitch()
    let secret = UITextField()
    var timer: Timer?

    init(capture: ScreenEventsTouchCapture) {
        self.capture = capture
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        canvas.capture = capture
        canvas.backgroundColor = .secondarySystemBackground
        canvas.accessibilityIdentifier = "canvas"

        status.numberOfLines = 0
        status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        status.accessibilityIdentifier = "status"

        share.isOn = capture.userEnabled
        share.addAction(UIAction { [unowned self] _ in capture.userEnabled = share.isOn }, for: .valueChanged)
        force.isOn = capture.ignoreCaptureState
        force.addAction(UIAction { [unowned self] _ in capture.ignoreCaptureState = force.isOn }, for: .valueChanged)

        secret.placeholder = "Password (pauses events while editing)"
        secret.isSecureTextEntry = true
        secret.borderStyle = .roundedRect
        secret.delegate = self

        let clear = UIButton(type: .system, primaryAction: UIAction(title: "Clear") { [unowned self] _ in canvas.clear() })

        func row(_ text: String, _ s: UISwitch) -> UIStackView {
            let l = UILabel(); l.text = text; l.font = .preferredFont(forTextStyle: .subheadline)
            let r = UIStackView(arrangedSubviews: [s, l]); r.spacing = 8; return r
        }
        let controls = UIStackView(arrangedSubviews: [row("Share touches with screen recorders", share), row("Ignore capture state (testing)", force), secret, clear])
        controls.axis = .horizontal
        controls.spacing = 16
        controls.alignment = .center
        controls.distribution = .fillProportionally

        let top = UIStackView(arrangedSubviews: [status, controls])
        top.axis = .vertical
        top.spacing = 8
        for v in [top, canvas] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            secret.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let state: String
        switch capture.client.state {
        case .idle: state = "idle"
        case .searching: state = "searching"
        case .connected(let r, let port): state = "connected to \(r.name ?? r.id) on :\(port)"
        }
        status.text = "captured: \(capture.isScreenCaptured ? "yes" : "no") · \(state) · sent: \(capture.client.sent)\(capture.paused ? " · PAUSED (secure entry)" : "")"
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { capture.setPaused(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { capture.setPaused(false) }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
}

/// Draws what you touch, so there's something to see in the recording.
final class CanvasView: UIView {
    weak var capture: ScreenEventsTouchCapture?
    private var strokes: [[CGPoint]] = []
    private var live: [ObjectIdentifier: Int] = [:]

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true }
    required init?(coder: NSCoder) { fatalError() }

    func clear() { strokes.removeAll(); live.removeAll(); setNeedsDisplay() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { live[ObjectIdentifier(t)] = strokes.count; strokes.append([t.preciseLocation(in: self)]) }
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let i = live[ObjectIdentifier(t)] else { continue }
            for c in event?.coalescedTouches(for: t) ?? [t] { strokes[i].append(c.preciseLocation(in: self)) }
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { live[ObjectIdentifier(t)] = nil } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) { capture?.estimatedPropertiesUpdated(touches) }

    override func draw(_ rect: CGRect) {
        UIColor.label.setStroke()
        for s in strokes {
            let p = UIBezierPath()
            p.lineWidth = 3; p.lineCapStyle = .round; p.lineJoinStyle = .round
            guard let f = s.first else { continue }
            p.move(to: f)
            if s.count == 1 { p.addLine(to: f) }
            for q in s.dropFirst() { p.addLine(to: q) }
            p.stroke()
        }
    }
}
