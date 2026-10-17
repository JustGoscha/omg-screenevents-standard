import Foundation
import Network

/// The Source side: while `active`, finds a Recorder on loopback, does the handshake and sends events.
/// Platform glue (capture state, UITouch conversion) lives in TouchCapture.swift.
public final class ScreenEventsSource: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case searching
        case connected(recorder: Peer, port: UInt16)
    }

    public let source: Peer
    public let capabilities: [String]
    public let ports: [UInt16]
    /// How long a port gets to answer `hello` before the next is tried (SPEC.md §4.1).
    public var handshakeTimeout: TimeInterval = 1
    private let queue: DispatchQueue
    private var channel: LineChannel?
    private var attempt = 0
    private var backoff: TimeInterval = 0.5
    private var generation = 0

    public private(set) var want: Set<String> = []
    public private(set) var maxRate: Double?
    public private(set) var state: State = .idle { didSet { if state != oldValue { onState?(state) } } }
    public private(set) var sent = 0

    /// Callbacks run on `queue`.
    public var onState: ((State) -> Void)?
    /// The handshake finished: send `display` and `hints` now.
    public var onConnected: (() -> Void)?
    public var onMessage: ((Message) -> Void)?

    public init(source: Peer,
                capabilities: [String] = ["touch", "pencil", "hover", "pointer", "estimated", "predicted", "pencil-actions"],
                ports: [UInt16] = screenEventsPorts,
                queue: DispatchQueue = .main) {
        self.source = source; self.capabilities = capabilities; self.ports = ports; self.queue = queue
    }

    /// Connect while true; disconnect (with `bye`) when false. The Source only sets this while the screen is captured (SPEC.md §10.1).
    public var active = false {
        didSet {
            guard active != oldValue else { return }
            queue.async { self.active ? self.begin() : self.end() }
        }
    }

    public var isConnected: Bool { if case .connected = state { return true }; return false }

    /// Sends a message if connected and the Recorder wants its kind; otherwise drops it.
    public func send(_ m: Message) {
        queue.async {
            guard self.isConnected, let ch = self.channel else { return }
            if let cap = m.capability, !self.want.contains(cap) { return }
            ch.send(m)
            self.sent += 1
        }
    }

    public func wants(_ capability: String) -> Bool { want.contains(capability) }

    private func begin() {
        backoff = 0.5
        attempt = 0
        state = .searching
        connect()
    }

    private func end() {
        generation += 1
        if let ch = channel { ch.send(.bye); ch.close() }
        channel = nil
        state = .idle
    }

    private func connect() {
        guard active else { return }
        generation += 1
        let gen = generation
        let port = ports[attempt % ports.count]
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ch = LineChannel(c, queue: queue)
        channel = ch
        var welcomed = false
        ch.onReady = { [weak self] in
            guard let self else { return }
            ch.send(.hello(Hello(source: self.source, capabilities: self.capabilities)))
        }
        ch.onMessage = { [weak self] m in
            guard let self, gen == self.generation else { return }
            if !welcomed {
                guard case .welcome(let w) = m, w.version.hasPrefix("1.") else { ch.close(); return }
                welcomed = true
                self.want = Set(w.want ?? self.capabilities)
                self.maxRate = w.maxRate
                self.backoff = 0.5
                self.state = .connected(recorder: w.recorder, port: port)
                self.onConnected?()
                return
            }
            switch m {
            case .ping(let p): ch.send(.pong(Pong(n: p.n, t: p.t, rt: hostTime())))
            case .bye: ch.close()
            default: break
            }
            self.onMessage?(m)
        }
        ch.onClose = { [weak self] _ in
            guard let self, gen == self.generation else { return }
            self.channel = nil
            self.next(afterSession: welcomed)
        }
        ch.start()
        queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
            // a port that accepts but never answers (e.g. a suspended app) is skipped
            guard let self, gen == self.generation, !welcomed else { return }
            ch.close()
        }
    }

    private func next(afterSession: Bool) {
        guard active else { return }
        state = .searching
        if afterSession {
            attempt = 0
            connect()
            return
        }
        attempt += 1
        if attempt % ports.count == 0 {
            let delay = backoff
            backoff = min(backoff * 2, 10)
            let gen = generation
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.connect()
            }
        } else {
            connect()
        }
    }
}
