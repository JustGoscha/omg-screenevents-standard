import Network
import XCTest
@testable import ScreenEventsKit

/// Real TCP over 127.0.0.1 between a Recorder and a Source, on test ports so a running recorder doesn't interfere.
final class LoopbackTests: XCTestCase {
    let ports: [UInt16] = [57833, 57834, 57835, 57836]
    let rq = DispatchQueue(label: "recorder")
    let sq = DispatchQueue(label: "source")

    func finger(_ id: Int, _ phase: String, seq: Int, x: Double) -> Message {
        .touch(Touch(id: id, kind: "finger", phase: phase, screen: "main", samples: [Sample(seq: seq, t: hostTime(), x: x, y: 10)]))
    }

    func testHandshakeTouchesAndDisconnect() throws {
        let rec = ScreenEventsRecorder(recorder: Peer(id: "test.recorder", name: "Rec"), ports: ports, queue: rq)
        let listening = expectation(description: "listening")
        let started = expectation(description: "session")
        let gotTouches = expectation(description: "touches")
        let ended = expectation(description: "end")
        var received: [Message] = []
        rec.onState = { if case .listening = $0 { listening.fulfill() } }
        rec.onSessionStart = { s in XCTAssertEqual(s.source?.id, "test.source"); started.fulfill() }
        rec.onMessage = { _, m in
            received.append(m)
            if case .touch(let t) = m, t.phase == "ended" { gotTouches.fulfill() }
        }
        rec.onSessionEnd = { _ in ended.fulfill() }
        rec.start()
        wait(for: [listening], timeout: 2)

        let src = ScreenEventsSource(source: Peer(id: "test.source"), ports: ports, queue: sq)
        let connected = expectation(description: "connected")
        src.onConnected = { connected.fulfill() }
        src.active = true
        wait(for: [started, connected], timeout: 3)
        if case .connected(let r, let port) = src.state {
            XCTAssertEqual(r.id, "test.recorder"); XCTAssertEqual(port, ports[0])
        } else { XCTFail("not connected: \(src.state)") }

        src.send(.display(Display(t: hostTime(), screen: .init(id: "main", size: [1024, 1366], scale: 2, rotation: 90), windows: nil)))
        src.send(finger(1, "began", seq: 1, x: 1))
        src.send(finger(1, "moved", seq: 2, x: 2))
        src.send(finger(1, "ended", seq: 3, x: 3))
        wait(for: [gotTouches], timeout: 2)
        let touches = received.compactMap { if case .touch(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(touches.map(\.phase), ["began", "moved", "ended"])
        XCTAssertEqual(touches.last?.samples.first?.x, 3)
        XCTAssertTrue(received.contains { if case .display(let d) = $0 { return d.screen.rotation == 90 } else { return false } })

        src.active = false
        wait(for: [ended], timeout: 2)
        rec.stop()
    }

    /// A port held by something that accepts but never answers: the Recorder binds the next port,
    /// the Source times out on the squatter and finds the Recorder (SPEC.md §4.1).
    func testPortFallback() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: ports[0])!)
        let squatter = try NWListener(using: params)
        var held: [NWConnection] = []
        squatter.newConnectionHandler = { c in held.append(c); c.start(queue: self.rq) }   // never replies
        let up = expectation(description: "squatter up")
        squatter.stateUpdateHandler = { if case .ready = $0 { up.fulfill() } }
        squatter.start(queue: rq)
        wait(for: [up], timeout: 2)

        let rec = ScreenEventsRecorder(recorder: Peer(id: "test.recorder"), ports: ports, queue: rq)
        let listening = expectation(description: "listening")
        rec.onState = { if case .listening(let p) = $0 { XCTAssertEqual(p, self.ports[1]); listening.fulfill() } }
        rec.start()
        wait(for: [listening], timeout: 3)

        let src = ScreenEventsSource(source: Peer(id: "test.source"), ports: ports, queue: sq)
        src.handshakeTimeout = 0.3
        let connected = expectation(description: "connected")
        src.onConnected = { connected.fulfill() }
        src.active = true
        wait(for: [connected], timeout: 3)
        if case .connected(_, let port) = src.state { XCTAssertEqual(port, ports[1]) } else { XCTFail() }
        src.active = false
        rec.stop()
        squatter.cancel()
    }

    /// Kinds the Recorder didn't ask for are never sent (SPEC.md §6.1).
    func testWantFiltersKinds() throws {
        let rec = ScreenEventsRecorder(recorder: Peer(id: "test.recorder"), want: ["touch"], ports: ports, queue: rq)
        let listening = expectation(description: "listening")
        rec.onState = { if case .listening = $0 { listening.fulfill() } }
        var kinds: [String] = []
        let done = expectation(description: "finger arrived")
        rec.onMessage = { _, m in
            if case .touch(let t) = m { kinds.append(t.kind); if t.kind == "finger" { done.fulfill() } }
        }
        rec.start()
        wait(for: [listening], timeout: 2)
        let src = ScreenEventsSource(source: Peer(id: "test.source"), ports: ports, queue: sq)
        let connected = expectation(description: "connected")
        src.onConnected = { connected.fulfill() }
        src.active = true
        wait(for: [connected], timeout: 3)
        src.send(.touch(Touch(id: 1, kind: "pencil", phase: "began", screen: "main", samples: [Sample(seq: 1, t: 0, x: 0, y: 0)])))
        src.send(finger(2, "began", seq: 1, x: 0))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(kinds, ["finger"])
        src.active = false
        rec.stop()
    }

    func testDecodeIgnoresUnknown() throws {
        let m = try Message.decode(Data(#"{"type":"future-thing","x":1}"#.utf8))
        guard case .unknown("future-thing") = m else { return XCTFail("\(m)") }
        let t = try Message.decode(Data(#"{"type":"touch","id":1,"kind":"pencil","phase":"began","screen":"main","newField":true,"samples":[{"seq":1,"t":1,"x":2,"y":3,"azimuth":0.5,"zzz":1}]}"#.utf8))
        guard case .touch(let touch) = t else { return XCTFail() }
        XCTAssertEqual(touch.samples[0].azimuth, 0.5)
    }

    /// Writes one of every message for the JSON Schema check (scripts/validate-swift-output.sh).
    func testDumpForSchema() throws {
        guard let path = ProcessInfo.processInfo.environment["SE_DUMP"] else { throw XCTSkip("set SE_DUMP to write messages") }
        var s = Sample(seq: 1, t: 1, x: 2, y: 3)
        s.force = 0.5; s.altitude = 1; s.azimuth = 2; s.roll = 0.1; s.estimated = ["force"]
        var u = Update(id: 1, seq: 1); u.force = 0.6; u.final = true
        let all: [Message] = [
            .hello(Hello(source: Peer(id: "a.b", name: "A", version: "1", pid: 1), capabilities: ["touch"])),
            .welcome(Welcome(recorder: Peer(id: "c.d"), want: ["touch"], maxRate: 240)),
            .display(Display(t: 1, screen: .init(id: "main", size: [1024, 1366], scale: 2, rotation: 270), windows: [.init(id: "w", frame: [0, 0, 1, 1], key: true)])),
            .touch(Touch(id: 1, kind: "pencil", phase: "moved", screen: "main", samples: [s], predicted: [s])),
            .update(u),
            .action(Action(t: 1, name: "pencil-squeeze", phase: "ended", hover: .init(x: 1, y: 2))),
            .hints(Hints(selfRendered: ["finger"], suppress: false)),
            .privacy(Privacy(state: "paused", reason: "secure-entry")),
            .ping(Ping(n: 1, t: 1)), .pong(Pong(n: 1, t: 1, rt: 1.1)), .bye,
        ]
        var data = Data()
        for m in all { data.append(m.line()) }
        let enc = JSONEncoder()
        data.append(try enc.encode(Sidecar(videoStart: 1, recorder: Peer(id: "c.d")))); data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
