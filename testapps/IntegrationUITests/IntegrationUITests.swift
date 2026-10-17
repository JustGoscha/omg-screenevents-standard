import XCTest

/// Two separate apps in the simulator: SE Recorder (in-app listener, kept running in the
/// background) and SE Source (in front, real touches). Checks that the Source finds the
/// Recorder over loopback and that every contact arrives began → ended.
/// SE Recorder must be installed first (scripts/sim-test.sh does that).
final class IntegrationUITests: XCTestCase {
    let recorder = XCUIApplication(bundleIdentifier: "app.omg.screenevents.recorder")

    func count(_ label: String, _ key: String) -> Int {
        guard let r = label.range(of: "\(key)=(\\d+)", options: .regularExpression) else { return 0 }
        return Int(label[r].split(separator: "=")[1]) ?? 0
    }

    func waitFor(_ el: XCUIElement, timeout: TimeInterval = 10, _ ok: (String) -> Bool) -> String {
        let end = Date().addingTimeInterval(timeout)
        var label = ""
        while Date() < end {
            label = el.label
            if ok(label) { return label }
            usleep(200_000)
        }
        return label
    }

    func testSourceTalksToRecorder() throws {
        recorder.launchArguments = ["-SEInAppListener"]
        recorder.launch()
        let inapp = recorder.staticTexts["inapp"]
        XCTAssertTrue(inapp.waitForExistence(timeout: 10))
        let l0 = waitFor(inapp) { $0.contains("listening :") }
        XCTAssertTrue(l0.contains("listening :47833"), l0)

        let source = XCUIApplication()
        source.launchArguments = ["-SEForceCapture"]
        source.launch()
        let status = source.staticTexts["status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let s0 = waitFor(status) { $0.contains("connected to") }
        XCTAssertTrue(s0.contains("connected to SE Recorder (in-app) on :47833"), s0)

        let canvas = source.otherElements["canvas"]
        let strokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.2, 0.3, 0.8, 0.35), (0.3, 0.5, 0.6, 0.8), (0.7, 0.6, 0.2, 0.7)]
        for (x0, y0, x1, y1) in strokes {
            let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: x0, dy: y0))
            let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: 400, thenHoldForDuration: 0.05)
        }
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let s1 = status.label
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)

        recorder.activate()
        let l1 = waitFor(inapp) { self.count($0, "ended") >= 4 }
        let shot2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot2.lifetime = .keepAlways; add(shot2)
        print("SOURCE STATUS: \(s1)\nRECORDER COUNTS:\n\(l1)")
        XCTAssertGreaterThanOrEqual(count(l1, "began"), 4, l1)
        XCTAssertEqual(count(l1, "began"), count(l1, "ended") + count(l1, "cancelled"), l1)
        XCTAssertGreaterThanOrEqual(count(l1, "finger"), 8, l1)
        XCTAssertGreaterThanOrEqual(count(l1, "display"), 1, l1)
        XCTAssertGreaterThanOrEqual(count(l1, "hints"), 1, l1)
        XCTAssertTrue(l1.contains("rot 0"), l1)

        // rotate: positions stay in the fixed (portrait) space, display reports the interface rotation (SPEC.md §8)
        XCUIDevice.shared.orientation = .landscapeLeft
        source.activate()
        sleep(2)
        let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: 400, thenHoldForDuration: 0.05)
        sleep(1)
        recorder.activate()
        let l2 = waitFor(inapp) { self.count($0, "ended") >= 5 }
        let shot3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot3.lifetime = .keepAlways; add(shot3)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "se-recorder.png"))
        print("ROTATED COUNTS:\n\(l2)")
        XCTAssertGreaterThanOrEqual(count(l2, "display"), 2, l2)
        XCTAssertTrue(l2.contains("834×1210@2x rot 90") || l2.contains("834×1210@2x rot 270"), l2)
        XCUIDevice.shared.orientation = .portrait
    }
}
