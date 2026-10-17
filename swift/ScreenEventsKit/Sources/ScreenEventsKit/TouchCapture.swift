#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Turns a window's UIKit input into ScreenEvents messages (SPEC.md §6.3, §8) and runs the
/// Source connection only while the screen is captured and the user allows it (SPEC.md §10).
///
/// Wire it up by using `ScreenEventsWindow`, or by calling `handle(_:)` from your own
/// window's `sendEvent(_:)` and `refreshDisplay()` from its `layoutSubviews()`.
@MainActor
public final class ScreenEventsTouchCapture: NSObject {
    public let client: ScreenEventsSource
    public weak var window: UIWindow?

    /// The user's setting ("Share touches with screen recorders"). Off by default (SPEC.md §10.2).
    public var userEnabled = false { didSet { refreshActive() } }
    /// Testing only: send even when the screen isn't captured (the simulator never is).
    public var ignoreCaptureState = false { didSet { refreshActive() } }
    /// Kinds this app draws its own indicators for (SPEC.md §6.6).
    public var selfRendered: [String] = [] { didSet { sendHints() } }

    public private(set) var paused = false

    private struct Contact { var id: Int; var kind: String; var seq = 0; var last = (x: 0.0, y: 0.0); var byEstimationIndex: [Int: Int] = [:] }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var hoverContact: (id: Int, seq: Int, last: (x: Double, y: Double))?
    private var nextID = 1
    private var lastDisplay: Display?
    private let screenID = "main"

    public init(window: UIWindow, source: Peer) {
        self.window = window
        self.client = ScreenEventsSource(source: source)
        super.init()
        client.onConnected = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastDisplay = nil
                self.refreshDisplay()
                self.sendHints()
                if self.paused { self.client.send(.privacy(Privacy(state: "paused", reason: "secure-entry"))) }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(captureChanged), name: UIScreen.capturedDidChangeNotification, object: nil)
        installRecognizers(on: window)
    }

    public var isScreenCaptured: Bool {
        guard let window else { return false }
        if #available(iOS 17.0, *) { return window.traitCollection.sceneCaptureState == .active }
        return window.screen.isCaptured
    }

    @objc private func captureChanged() { refreshActive() }

    private func refreshActive() {
        client.active = userEnabled && (isScreenCaptured || ignoreCaptureState)
    }

    // MARK: privacy (SPEC.md §6.7)

    /// Pause around secure entry: open contacts are cancelled first.
    public func setPaused(_ p: Bool, reason: String = "secure-entry") {
        guard p != paused else { return }
        if p { cancelAll() }
        paused = p
        client.send(.privacy(Privacy(state: p ? "paused" : "resumed", reason: p ? reason : nil)))
    }

    private func cancelAll() {
        for c in contacts.values {
            client.send(.touch(Touch(id: c.id, kind: c.kind, phase: "cancelled", screen: screenID,
                                     samples: [Sample(seq: c.seq + 1, t: hostTime(), x: c.last.x, y: c.last.y)])))
        }
        contacts.removeAll()
        if let h = hoverContact {
            client.send(.touch(Touch(id: h.id, kind: "pencil", phase: "hover-ended", screen: screenID,
                                     samples: [Sample(seq: h.seq + 1, t: hostTime(), x: h.last.x, y: h.last.y)])))
            hoverContact = nil
        }
    }

    // MARK: geometry (SPEC.md §6.2, §8)

    private var fixed: UICoordinateSpace? { window?.screen.fixedCoordinateSpace }

    public func refreshDisplay() {
        guard let window, let fixed else { return }
        let size = fixed.bounds.size
        // interface rotation = where the window's "up" points in fixed space
        let o = window.convert(CGPoint(x: 0, y: 0), to: fixed)
        let u = window.convert(CGPoint(x: 0, y: -1), to: fixed)
        let a = atan2(u.y - o.y, u.x - o.x) * 180 / .pi   // -90 = no rotation
        var rot = Int((a + 90).rounded())
        rot = ((rot % 360) + 360) % 360
        rot = (rot + 45) / 90 * 90 % 360
        let f = window.convert(window.bounds, to: fixed)
        let d = Display(t: hostTime(),
                        screen: .init(id: screenID, size: [size.width, size.height], scale: window.screen.scale, rotation: rot),
                        windows: [.init(id: "w\(UInt(bitPattern: ObjectIdentifier(window).hashValue) % 10000)",
                                        frame: [f.minX, f.minY, f.width, f.height], key: window.isKeyWindow)])
        var cmp = d; cmp.t = lastDisplay?.t ?? 0
        guard lastDisplay == nil || cmp != lastDisplay else { return }
        lastDisplay = d
        client.send(.display(d))
    }

    private func sendHints() {
        client.send(.hints(Hints(selfRendered: selfRendered, suppress: false)))
    }

    private func point(_ p: CGPoint) -> (Double, Double) {
        guard let window, let fixed else { return (p.x, p.y) }
        let q = window.convert(p, to: fixed)
        return (q.x, q.y)
    }

    // MARK: touches

    private static func kind(_ t: UITouch) -> String {
        switch t.type {
        case .pencil: return "pencil"
        case .indirectPointer: return "pointer"
        default: return "finger"
        }
    }

    private static func phase(_ t: UITouch) -> String? {
        switch t.phase {
        case .began: return "began"
        case .moved: return "moved"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        default: return nil   // stationary and region phases aren't sent
        }
    }

    private func sample(_ t: UITouch, seq: Int) -> Sample {
        guard let window, let fixed else { return Sample(seq: seq, t: t.timestamp, x: 0, y: 0) }
        let loc = t.preciseLocation(in: window)
        let p = window.convert(loc, to: fixed)
        var s = Sample(seq: seq, t: t.timestamp, x: p.x, y: p.y)
        switch t.type {
        case .pencil:
            if t.maximumPossibleForce > 0 { s.force = min(1, Double(t.force / t.maximumPossibleForce)) }
            s.altitude = Double(t.altitudeAngle)
            // convert the barrel direction as a vector so interface rotation is accounted for (SPEC.md §8.2)
            let v = t.azimuthUnitVector(in: window)
            let p1 = window.convert(CGPoint(x: loc.x + v.dx, y: loc.y + v.dy), to: fixed)
            s.azimuth = atan2(p1.y - p.y, p1.x - p.x)
            if #available(iOS 17.5, *) { s.roll = Double(t.rollAngle) }
            var est: [String] = []
            let e = t.estimatedPropertiesExpectingUpdates
            if e.contains(.force) { est.append("force") }
            if e.contains(.altitude) { est.append("altitude") }
            if e.contains(.azimuth) { est.append("azimuth") }
            if e.contains(.location) { est.append(contentsOf: ["x", "y"]) }
            if #available(iOS 17.5, *), e.contains(.roll) { est.append("roll") }
            if !est.isEmpty { s.estimated = est }
        case .direct:
            s.radius = Double(t.majorRadius)
            s.radiusTolerance = Double(t.majorRadiusTolerance)
            if window.traitCollection.forceTouchCapability == .available, t.maximumPossibleForce > 0 {
                s.force = min(1, Double(t.force / t.maximumPossibleForce))
            }
        default: break
        }
        return s
    }

    /// Call from `UIWindow.sendEvent(_:)` before `super`.
    public func handle(_ event: UIEvent) {
        guard client.isConnected, !paused, event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.window === window {
            guard let phase = Self.phase(touch) else { continue }
            let key = ObjectIdentifier(touch)
            if phase == "began" || contacts[key] == nil {
                guard phase == "began" else { continue }
                contacts[key] = Contact(id: nextID, kind: Self.kind(touch))
                nextID += 1
            }
            guard var c = contacts[key] else { continue }
            let kind = c.kind
            let coalesced = event.coalescedTouches(for: touch) ?? [touch]
            var samples: [Sample] = []
            for ct in coalesced {
                c.seq += 1
                if let idx = ct.estimationUpdateIndex?.intValue { c.byEstimationIndex[idx] = c.seq }
                samples.append(sample(ct, seq: c.seq))
            }
            if let l = samples.last { c.last = (l.x, l.y) }
            var predicted: [Sample]?
            if client.wants("predicted"), let pr = event.predictedTouches(for: touch), !pr.isEmpty {
                predicted = pr.map { sample($0, seq: c.seq) }
            }
            client.send(.touch(Touch(id: c.id, kind: kind, phase: phase, screen: screenID, samples: samples, predicted: predicted)))
            if phase == "ended" || phase == "cancelled" { contacts[key] = nil } else { contacts[key] = c }
        }
    }

    /// Forward from the responder's `touchesEstimatedPropertiesUpdated(_:)` (SPEC.md §6.4).
    public func estimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard client.isConnected, !paused else { return }
        for t in touches {
            // the update's UITouch may be a different object than the live one; match by estimation index
            guard let idx = t.estimationUpdateIndex?.intValue,
                  let c = contacts.values.first(where: { $0.byEstimationIndex[idx] != nil }),
                  let seq = c.byEstimationIndex[idx], let window, let fixed else { continue }
            var u = Update(id: c.id, seq: seq)
            if t.maximumPossibleForce > 0 { u.force = min(1, Double(t.force / t.maximumPossibleForce)) }
            u.altitude = Double(t.altitudeAngle)
            let loc = t.preciseLocation(in: window)
            let p = window.convert(loc, to: fixed)
            let v = t.azimuthUnitVector(in: window)
            let p1 = window.convert(CGPoint(x: loc.x + v.dx, y: loc.y + v.dy), to: fixed)
            u.azimuth = atan2(p1.y - p.y, p1.x - p.x)
            u.final = t.estimatedPropertiesExpectingUpdates.isEmpty
            client.send(.update(u))
        }
    }

    // MARK: hover and Pencil actions

    private func installRecognizers(on window: UIWindow) {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHover(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false
        window.addGestureRecognizer(hover)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        window.addInteraction(pencil)
    }

    @objc private func pencilHover(_ g: UIHoverGestureRecognizer) {
        guard client.isConnected, !paused, let window else { return }
        let phase: String
        switch g.state {
        case .began:
            hoverContact = (nextID, 0, (0, 0)); nextID += 1
            phase = "hover-began"
        case .changed: phase = "hover"
        case .ended, .cancelled, .failed: phase = "hover-ended"
        default: return
        }
        guard var h = hoverContact else { return }
        h.seq += 1
        let (x, y) = point(g.location(in: window))
        h.last = (x, y)
        var s = Sample(seq: h.seq, t: hostTime(), x: x, y: y)
        if #available(iOS 16.1, *) { s.z = Double(g.zOffset) }
        if #available(iOS 16.4, *) {
            s.altitude = Double(g.altitudeAngle)
            let loc = g.location(in: window)
            let v = g.azimuthUnitVector(in: window)
            let (x1, y1) = point(CGPoint(x: loc.x + v.dx, y: loc.y + v.dy))
            s.azimuth = atan2(y1 - y, x1 - x)
        }
        if #available(iOS 17.5, *) { s.roll = Double(g.rollAngle) }
        client.send(.touch(Touch(id: h.id, kind: "pencil", phase: phase, screen: screenID, samples: [s])))
        hoverContact = phase == "hover-ended" ? nil : h
    }
}

extension ScreenEventsTouchCapture: UIPencilInteractionDelegate {
    public nonisolated func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        MainActor.assumeIsolated {
            client.send(.action(Action(t: hostTime(), name: "pencil-double-tap")))
        }
    }

    @available(iOS 17.5, *)
    public nonisolated func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        MainActor.assumeIsolated {
            let ph: String
            switch squeeze.phase {
            case .began: ph = "began"
            case .changed: ph = "changed"
            case .ended: ph = "ended"
            default: ph = "cancelled"
            }
            var hover: Action.Point?
            if let hp = squeeze.hoverPose, let window {
                let (x, y) = point(window.convert(hp.location, from: interaction.view))
                hover = .init(x: x, y: y)
            }
            client.send(.action(Action(t: squeeze.timestamp, name: "pencil-squeeze", phase: ph, hover: hover)))
        }
    }
}

/// A window that feeds its input to ScreenEvents. Assign `capture` after creating it.
open class ScreenEventsWindow: UIWindow {
    public var capture: ScreenEventsTouchCapture?

    open override func sendEvent(_ event: UIEvent) {
        capture?.handle(event)
        super.sendEvent(event)
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        capture?.refreshDisplay()
    }
}
#endif
