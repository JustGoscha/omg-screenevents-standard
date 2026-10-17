import Foundation

let appGroup = "group.app.omg.screenevents"

/// What a recorder saw, for checking the spec's assumptions on a device.
/// Written by the broadcast extension to the App Group, read by the Recorder app.
struct BroadcastStats: Codable {
    var updated = Date()
    var phase = "starting"            // starting | broadcasting | finished
    var listener = "–"                // listening :port, or the bind error
    var sources: [String] = []
    var sessionsEnded = 0
    var messages: [String: Int] = [:]
    var samples = 0
    var kinds: [String: Int] = [:]
    var lastDisplay: String?
    // video frames
    var frames = 0
    var firstFramePTS: Double?
    var lastFramePTS: Double?
    var bufferSize: String?
    var orientation: Int?
    // clocks (SPEC.md §7.1): sample time minus the newest frame's PTS, and arrival minus sample time
    var skewMin: Double?
    var skewMax: Double?
    var latencyMax: Double?
    var latencySum = 0.0
    var sidecar: String?

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("ScreenEvents", isDirectory: true)
    }
    static var url: URL? { directory?.appendingPathComponent("stats.json") }

    static func load() -> BroadcastStats? {
        guard let u = url, let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BroadcastStats.self, from: d)
    }

    func save() {
        guard let u = Self.url else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: u, options: .atomic)
    }

    mutating func noteSamples(_ ts: [Double], now: Double) {
        samples += ts.count
        for t in ts {
            if let f = lastFramePTS {
                let s = t - f
                skewMin = min(skewMin ?? s, s); skewMax = max(skewMax ?? s, s)
            }
            let l = now - t
            latencyMax = max(latencyMax ?? l, l); latencySum += l
        }
    }

    var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "–" }
        let msgs = messages.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let k = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        \(phase) · updated \(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))
        listener: \(listener) · sources: \(sources.isEmpty ? "none" : sources.joined(separator: ", ")) · ended: \(sessionsEnded)
        messages: \(msgs.isEmpty ? "none" : msgs)
        samples: \(samples) · kinds: \(k.isEmpty ? "none" : k)
        display: \(lastDisplay ?? "–")
        frames: \(frames) · buffer \(bufferSize ?? "–") · orientation \(orientation.map(String.init) ?? "–") · PTS \(f(firstFramePTS))…\(f(lastFramePTS))
        clock skew (sample t − newest frame PTS): \(f(skewMin))…\(f(skewMax)) s
        latency (arrival − t): avg \(samples > 0 ? f(latencySum / Double(samples)) : "–") max \(f(latencyMax)) s
        sidecar: \(sidecar ?? "–")
        """
    }
}
