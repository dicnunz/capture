import AppKit
import ScreenCaptureKit

extension AppDelegate {
    func runVerification() async {
        let args = CommandLine.arguments
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/verification", isDirectory: true)
        let actual = args.firstIndex(of: "--verification-output").flatMap { index in index + 1 < args.count ? URL(fileURLWithPath: args[index+1]) : nil } ?? output
        var results: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            let content = try await model.engine.catalog()
            guard let fixture = content.windows.first(where: { $0.owningApplication?.bundleIdentifier == "local.nic.CaptureToneA" }),
                  let fixtureApp = fixture.owningApplication,
                  let display = content.displays.first(where: { $0.frame.intersects(fixture.frame) }) else {
                throw UserError("Verification fixtures are not visible. Launch both test source apps first.")
            }
            let region = CGRect(x: fixture.frame.minX - display.frame.minX, y: fixture.frame.minY - display.frame.minY,
                                width: fixture.frame.width, height: fixture.frame.height)
            for (name, target) in [("screen", CaptureTarget.display(display.displayID)),
                                   ("window", CaptureTarget.window(fixture.windowID)),
                                   ("area", CaptureTarget.region(displayID: display.displayID, rect: region))] {
                let url = actual.appendingPathComponent("\(name).png")
                try await model.engine.captureScreenshot(target, to: url)
                let image = NSImage(contentsOf: url)
                results["screenshot_\(name)"] = ["saved": image != nil, "path": url.path]
            }
            let tests: [(String, AudioSource)] = [("silent", .none), ("system", .system), ("app", .application(fixtureApp.processID))]
            for (name, source) in tests {
                let url = actual.appendingPathComponent("\(name).mp4")
                try await model.engine.startRecording(.region(displayID: display.displayID, rect: region), audio: source, to: url)
                try await Task.sleep(nanoseconds: 3_300_000_000)
                let saved = try await model.engine.stopRecording()
                results["recording_\(name)"] = ["path": saved.path, "bytes": (try? saved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0]
            }
            let windowRecording = actual.appendingPathComponent("window.mp4")
            try await model.engine.startRecording(.window(fixture.windowID), audio: .none, to: windowRecording)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try await model.engine.stopRecording()
            results["recording_window"] = ["path": windowRecording.path]
            let screenRecording = actual.appendingPathComponent("screen.mp4")
            try await model.engine.startRecording(.display(display.displayID), audio: .none, to: screenRecording)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try await model.engine.stopRecording()
            results["recording_screen"] = ["path": screenRecording.path]
            results["capture_api_completed"] = true
        } catch {
            results["capture_api_completed"] = false
            results["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: actual.appendingPathComponent("capture-results.json"))
        }
        NSApp.terminate(nil)
    }
}
