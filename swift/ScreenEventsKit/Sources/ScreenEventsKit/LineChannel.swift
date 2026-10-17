import Foundation
import Network

/// NDJSON over one NWConnection: splits incoming bytes into lines (SPEC.md §5).
final class LineChannel: @unchecked Sendable {
    static let maxLine = 64 * 1024

    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    var onClose: ((NWError?) -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let e): self.close(e)
            case .waiting(let e): self.close(e)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ m: Message) {
        guard !closed else { return }
        connection.send(content: m.line(), completion: .contentProcessed { [weak self] e in
            if let e { self?.close(e) }
        })
    }

    func close(_ error: NWError? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
        onClose = nil; onMessage = nil; onReady = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.consume(data) }
            if done || error != nil { self.close(error) } else { self.receive() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            // a malformed line is dropped; one bad message shouldn't end the session
            if let m = try? Message.decode(Data(line)) { onMessage?(m) }
            if closed { return }
        }
        if buffer.count > Self.maxLine { close() }
    }
}
