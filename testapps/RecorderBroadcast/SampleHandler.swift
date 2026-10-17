import CoreMedia
import ReplayKit
import ScreenEventsKit

/// The system-wide recorder. It doesn't draw anything; it checks the spec's device assumptions:
/// that the extension can listen on loopback, that Sources find it, and that touch times and
/// frame PTS share a clock. Results go to the App Group (stats.json + a sidecar file).
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "screenevents.recorder")
    private var recorder: ScreenEventsRecorder?
    private var stats = BroadcastStats()
    private var sidecar: FileHandle?
    private var pending: [Data] = []
    private var lastSave = 0.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async { [self] in
            stats = BroadcastStats()
            stats.save()
            let rec = ScreenEventsRecorder(recorder: Peer(id: "app.omg.screenevents.recorder.broadcast", name: "SE Recorder (broadcast)", version: "1.0"), queue: queue)
            rec.onState = { [weak self] st in
                guard let self else { return }
                switch st {
                case .listening(let p): stats.listener = "listening :\(p)"
                case .failed(let e): stats.listener = "failed: \(e)"
                case .stopped: stats.listener = "stopped"
                }
                stats.save()
            }
            rec.onSessionStart = { [weak self] s in
                self?.stats.sources.append(s.source?.id ?? "?")
                self?.stats.save()
            }
            rec.onSessionEnd = { [weak self] _ in self?.stats.sessionsEnded += 1; self?.stats.save() }
            rec.onMessage = { [weak self] _, m in self?.received(m) }
            rec.start()
            recorder = rec
        }
    }

    private func received(_ m: Message) {
        let line = m.line()
        switch m {
        case .touch(let t):
            stats.messages["touch", default: 0] += 1
            stats.kinds[t.kind, default: 0] += t.samples.count
            stats.noteSamples(t.samples.map(\.t), now: hostTime())
        case .display(let d):
            stats.messages["display", default: 0] += 1
            stats.lastDisplay = "\(Int(d.screen.size[0]))×\(Int(d.screen.size[1]))@\(Int(d.screen.scale))x rot \(d.screen.rotation)"
        case .update: stats.messages["update", default: 0] += 1
        case .action(let a): stats.messages[a.name, default: 0] += 1
        case .privacy(let p): stats.messages["privacy-\(p.state)", default: 0] += 1
        case .hints: stats.messages["hints", default: 0] += 1
        default: break
        }
        write(line)
        saveSoon()
    }

    private func write(_ line: Data) {
        if let h = sidecar { h.write(line) } else { pending.append(line) }
    }

    private func saveSoon() {
        let now = hostTime()
        if now - lastSave > 0.5 { lastSave = now; stats.updated = Date(); stats.save() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var size: String?
        var orientation: Int?
        if let img = CMSampleBufferGetImageBuffer(sampleBuffer) {
            size = "\(CVPixelBufferGetWidth(img))×\(CVPixelBufferGetHeight(img))"
        }
        if let o = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            orientation = o.intValue
        }
        queue.async { [self] in
            stats.frames += 1
            stats.lastFramePTS = pts
            stats.bufferSize = size ?? stats.bufferSize
            stats.orientation = orientation ?? stats.orientation
            if stats.firstFramePTS == nil {
                stats.firstFramePTS = pts
                stats.phase = "broadcasting"
                openSidecar(videoStart: pts)
            }
            saveSoon()
        }
    }

    private func openSidecar(videoStart: Double) {
        guard let dir = BroadcastStats.directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "broadcast-\(Int(Date().timeIntervalSince1970)).screenevents.ndjson"
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        let header = Sidecar(videoStart: videoStart, recorder: recorder?.recorder)
        h.write((try? JSONEncoder().encode(header)) ?? Data())
        h.write(Data([0x0A]))
        for l in pending { h.write(l) }
        pending.removeAll()
        sidecar = h
        stats.sidecar = name
    }

    override func broadcastFinished() {
        queue.sync {
            recorder?.stop()
            try? sidecar?.close()
            stats.phase = "finished"
            stats.updated = Date()
            stats.save()
        }
    }
}
