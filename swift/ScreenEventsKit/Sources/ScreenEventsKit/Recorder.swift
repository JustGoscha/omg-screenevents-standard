import Foundation
import Network

/// The Recorder side: listens on loopback, answers the handshake, delivers each Source's messages.
public final class ScreenEventsRecorder: @unchecked Sendable {
    public final class Session: @unchecked Sendable {
        public let id = UUID()
        public fileprivate(set) var source: Peer?
        fileprivate let channel: LineChannel
        fileprivate init(_ channel: LineChannel) { self.channel = channel }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    public let recorder: Peer
    public let want: [String]
    public let maxRate: Double?
    public let ports: [UInt16]
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]

    /// All callbacks run on `queue`.
    public var onState: ((State) -> Void)?
    public var onSessionStart: ((Session) -> Void)?
    public var onMessage: ((Session, Message) -> Void)?
    /// The session closed; any contacts still open in it are cancelled (SPEC.md §6.3).
    public var onSessionEnd: ((Session) -> Void)?

    public private(set) var state: State = .stopped { didSet { onState?(state) } }

    public init(recorder: Peer,
                want: [String] = ["touch", "pencil", "hover", "pointer", "estimated", "pencil-actions"],
                maxRate: Double? = 240,
                ports: [UInt16] = screenEventsPorts,
                queue: DispatchQueue = .main) {
        self.recorder = recorder; self.want = want; self.maxRate = maxRate; self.ports = ports; self.queue = queue
    }

    public func start() {
        queue.async { self.bind(0) }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for s in self.sessions.values { s.channel.send(.bye); s.channel.close() }
            self.sessions.removeAll()
            self.state = .stopped
        }
    }

    public var sessionCount: Int { sessions.count }

    private func bind(_ i: Int) {
        guard i < ports.count else { state = .failed("all ports in use: \(ports)"); return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: ports[i])!)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { bind(i + 1); return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready: self.state = .listening(port: self.ports[i])
            case .failed, .waiting:
                l.cancel(); self.listener = nil
                self.bind(i + 1)
            default: break
            }
        }
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        let ch = LineChannel(c, queue: queue)
        let s = Session(ch)
        sessions[s.id] = s
        ch.onMessage = { [weak self, weak s] m in
            guard let self, let s else { return }
            self.handle(m, s)
        }
        ch.onClose = { [weak self] _ in
            guard let self, self.sessions.removeValue(forKey: s.id) != nil else { return }
            if s.source != nil { self.onSessionEnd?(s) }
        }
        ch.start()
    }

    private func handle(_ m: Message, _ s: Session) {
        if s.source == nil {
            // only `hello` is allowed before the handshake (SPEC.md §6.1)
            guard case .hello(let h) = m, h.protocol == "screenevents", h.version.hasPrefix("1.") else {
                s.channel.close(); return
            }
            s.source = h.source
            s.channel.send(.welcome(Welcome(recorder: recorder, want: want, maxRate: maxRate)))
            onSessionStart?(s)
            return
        }
        switch m {
        case .ping(let p): s.channel.send(.pong(Pong(n: p.n, t: p.t, rt: hostTime())))
        case .bye: s.channel.close()
        default: break
        }
        onMessage?(s, m)
    }
}
