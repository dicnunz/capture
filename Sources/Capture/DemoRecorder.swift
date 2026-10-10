import AppKit
import ScreenCaptureKit

extension AppDelegate {
    func startDemoRecording() async {
        let args = CommandLine.arguments
        guard let outputIndex = args.firstIndex(of: "--demo-output"), outputIndex + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[outputIndex + 1])
        do {
            let recorder = CaptureEngine()
            let content = try await recorder.catalog()
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw UserError("No display is connected.") }
            var rectangle = CGRect(x: display.frame.maxX - 850, y: 112, width: 830, height: 650)
            if let index = args.firstIndex(of: "--demo-rect"), index + 1 < args.count {
                let values = args[index+1].split(separator: ",").compactMap { Double($0) }
                if values.count == 4 { rectangle = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
            }
            demoRect = rectangle
            let local = rectangle.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            model.selectedDisplayID = display.displayID
            model.region = local
            model.mode = .region
            var settings = CaptureOptions()
            settings.quality = .original
            settings.showsCursor = true
            settings.includesCaptureUI = true
            let source: AudioSource
            if args.contains("--demo-no-audio") { source = .none }
            else if let index = args.firstIndex(of: "--demo-audio-pid"), index + 1 < args.count, let pid = Int32(args[index+1]) {
                source = .application(pid)
            } else { source = .system }
            try await recorder.startRecording(.region(displayID: display.displayID, rect: local), audio: source, to: output, options: settings)
            demoEngine = recorder
            showToolbar()
            let stop = NSMenuItem(title: "Finish Demo Recording", action: #selector(finishDemoRecording), keyEquivalent: "")
            stop.target = self; stop.tag = 99
            item.menu?.insertItem(stop, at: 0)
            logger.info("Independent self-demo capture started")
            if let index = args.firstIndex(of: "--demo-duration"), index + 1 < args.count, let seconds = Double(args[index+1]), seconds > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    finishDemoRecording()
                }
            }
        } catch { model.status = error.localizedDescription; showToolbar() }
    }

    @objc func finishDemoRecording() {
        Task { _ = await finalizeDemoRecording() }
    }

    func finalizeDemoRecording() async -> Bool {
        if let task = demoFinalizationTask { return await task.value }
        guard demoEngine != nil || demoStartTask != nil else { return true }
        let task = Task { @MainActor in
            await demoStartTask?.value
            guard let recorder = demoEngine else { return true }
            do {
                let url = try await recorder.stopRecording()
                demoEngine = nil
                logger.info("Self-demo saved: \(url.path, privacy: .public)")
                try? Data(url.path.utf8).write(to: url.deletingPathExtension().appendingPathExtension("done"))
                item.menu?.item(withTag: 99).map { item.menu?.removeItem($0) }
                demoRect = nil
                return true
            } catch {
                model.status = error.localizedDescription
                // The writer has stopped. Preserve its file and cancel this quit,
                // but allow a later explicit quit after the error is visible.
                demoEngine = nil
                demoStartTask = nil
                demoFinalizationTask = nil
                showToolbar()
                return false
            }
        }
        demoFinalizationTask = task
        return await task.value
    }
}
