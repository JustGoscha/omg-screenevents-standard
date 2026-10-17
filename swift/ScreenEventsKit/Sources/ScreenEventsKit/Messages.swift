import Foundation

/// The wire version this implementation speaks (SPEC.md §12).
public let screenEventsVersion = "1.0"
/// Loopback ports, in the order Recorders bind and Sources try them (SPEC.md §4.1).
public let screenEventsPorts: [UInt16] = [47833, 47834, 47835, 47836]

public struct Peer: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var version: String?
    public var pid: Int?
    public init(id: String, name: String? = nil, version: String? = nil, pid: Int? = nil) {
        self.id = id; self.name = name; self.version = version; self.pid = pid
    }
}

public struct Hello: Codable, Sendable {
    public var type = "hello"
    public var `protocol` = "screenevents"
    public var version = screenEventsVersion
    public var source: Peer
    public var clock = "host"
    public var capabilities: [String]
    public init(source: Peer, capabilities: [String]) { self.source = source; self.capabilities = capabilities }
}

public struct Welcome: Codable, Sendable {
    public var type = "welcome"
    public var version = screenEventsVersion
    public var recorder: Peer
    public var want: [String]?
    public var maxRate: Double?
    public init(recorder: Peer, want: [String]?, maxRate: Double?) { self.recorder = recorder; self.want = want; self.maxRate = maxRate }
}

public struct Display: Codable, Equatable, Sendable {
    public struct Screen: Codable, Equatable, Sendable {
        public var id: String
        public var size: [Double]
        public var scale: Double
        public var rotation: Int
        public init(id: String, size: [Double], scale: Double, rotation: Int) { self.id = id; self.size = size; self.scale = scale; self.rotation = rotation }
    }
    public struct Window: Codable, Equatable, Sendable {
        public var id: String
        public var frame: [Double]
        public var key: Bool?
        public init(id: String, frame: [Double], key: Bool?) { self.id = id; self.frame = frame; self.key = key }
    }
    public var type = "display"
    public var t: Double
    public var screen: Screen
    public var windows: [Window]?
    public init(t: Double, screen: Screen, windows: [Window]?) { self.t = t; self.screen = screen; self.windows = windows }
}

public struct Sample: Codable, Equatable, Sendable {
    public var seq: Int
    public var t: Double
    public var x: Double
    public var y: Double
    public var force: Double?
    public var altitude: Double?
    public var azimuth: Double?
    public var roll: Double?
    public var z: Double?
    public var radius: Double?
    public var radiusTolerance: Double?
    public var estimated: [String]?
    public init(seq: Int, t: Double, x: Double, y: Double) { self.seq = seq; self.t = t; self.x = x; self.y = y }
}

public struct Touch: Codable, Sendable {
    public var type = "touch"
    public var id: Int
    public var kind: String      // finger | pencil | pointer
    public var phase: String     // began | moved | stationary | ended | cancelled | hover-began | hover | hover-ended
    public var screen: String
    public var samples: [Sample]
    public var predicted: [Sample]?
    public var buttons: Int?
    public init(id: Int, kind: String, phase: String, screen: String, samples: [Sample], predicted: [Sample]? = nil) {
        self.id = id; self.kind = kind; self.phase = phase; self.screen = screen; self.samples = samples; self.predicted = predicted
    }
    public var isEnd: Bool { phase == "ended" || phase == "cancelled" || phase == "hover-ended" }
}

public struct Update: Codable, Sendable {
    public var type = "update"
    public var id: Int
    public var seq: Int
    public var force: Double?
    public var altitude: Double?
    public var azimuth: Double?
    public var roll: Double?
    public var final: Bool?
    public init(id: Int, seq: Int) { self.id = id; self.seq = seq }
}

public struct Action: Codable, Sendable {
    public struct Point: Codable, Sendable { public var x: Double; public var y: Double; public init(x: Double, y: Double) { self.x = x; self.y = y } }
    public var type = "action"
    public var t: Double
    public var name: String
    public var phase: String?
    public var hover: Point?
    public init(t: Double, name: String, phase: String? = nil, hover: Point? = nil) { self.t = t; self.name = name; self.phase = phase; self.hover = hover }
}

public struct Hints: Codable, Sendable {
    public var type = "hints"
    public var selfRendered: [String]?
    public var suppress: Bool?
    public init(selfRendered: [String]?, suppress: Bool?) { self.selfRendered = selfRendered; self.suppress = suppress }
}

public struct Privacy: Codable, Sendable {
    public var type = "privacy"
    public var state: String     // paused | resumed
    public var reason: String?
    public init(state: String, reason: String? = nil) { self.state = state; self.reason = reason }
}

public struct Ping: Codable, Sendable {
    public var type = "ping"
    public var n: Int
    public var t: Double
    public init(n: Int, t: Double) { self.n = n; self.t = t }
}

public struct Pong: Codable, Sendable {
    public var type = "pong"
    public var n: Int
    public var t: Double
    public var rt: Double
    public init(n: Int, t: Double, rt: Double) { self.n = n; self.t = t; self.rt = rt }
}

public struct Sidecar: Codable, Sendable {
    public var type = "sidecar"
    public var version = screenEventsVersion
    public var clock = "host"
    public var videoStart: Double
    public var recorder: Peer?
    public init(videoStart: Double, recorder: Peer?) { self.videoStart = videoStart; self.recorder = recorder }
}

public enum Message: Sendable {
    case hello(Hello), welcome(Welcome), display(Display), touch(Touch), update(Update), action(Action)
    case hints(Hints), privacy(Privacy), ping(Ping), pong(Pong), bye
    /// A type this implementation doesn't know; receivers ignore it (SPEC.md §3.6).
    case unknown(String)

    private struct Kind: Decodable { var type: String }

    public static func decode(_ line: Data) throws -> Message {
        let d = JSONDecoder()
        switch try d.decode(Kind.self, from: line).type {
        case "hello": return .hello(try d.decode(Hello.self, from: line))
        case "welcome": return .welcome(try d.decode(Welcome.self, from: line))
        case "display": return .display(try d.decode(Display.self, from: line))
        case "touch": return .touch(try d.decode(Touch.self, from: line))
        case "update": return .update(try d.decode(Update.self, from: line))
        case "action": return .action(try d.decode(Action.self, from: line))
        case "hints": return .hints(try d.decode(Hints.self, from: line))
        case "privacy": return .privacy(try d.decode(Privacy.self, from: line))
        case "ping": return .ping(try d.decode(Ping.self, from: line))
        case "pong": return .pong(try d.decode(Pong.self, from: line))
        case "bye": return .bye
        case let other: return .unknown(other)
        }
    }

    /// One NDJSON line, including the trailing newline.
    public func line() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        var data: Data
        switch self {
        case .hello(let m): data = try! e.encode(m)
        case .welcome(let m): data = try! e.encode(m)
        case .display(let m): data = try! e.encode(m)
        case .touch(let m): data = try! e.encode(m)
        case .update(let m): data = try! e.encode(m)
        case .action(let m): data = try! e.encode(m)
        case .hints(let m): data = try! e.encode(m)
        case .privacy(let m): data = try! e.encode(m)
        case .ping(let m): data = try! e.encode(m)
        case .pong(let m): data = try! e.encode(m)
        case .bye: data = Data(#"{"type":"bye"}"#.utf8)
        case .unknown(let t): data = try! e.encode(["type": t])
        }
        data.append(0x0A)
        return data
    }

    /// The capability a Recorder must `want` before a Source may send this (SPEC.md §6.1).
    var capability: String? {
        switch self {
        case .touch(let t):
            if t.phase.hasPrefix("hover") { return "hover" }
            return t.kind == "finger" ? "touch" : t.kind
        case .update: return "estimated"
        case .action: return "pencil-actions"
        default: return nil
        }
    }
}

/// Seconds on the host clock: the clock `UITouch.timestamp` and ReplayKit frames use (SPEC.md §7.1).
public func hostTime() -> Double { ProcessInfo.processInfo.systemUptime }
