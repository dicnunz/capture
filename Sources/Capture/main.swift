import AppKit
import SwiftUI
import Carbon
import OSLog

private final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CaptureModel()
    var panel: NSPanel!
    var resultPanel: NSPanel!
    var feedbackPanel: NSPanel!
    var demoEngine: CaptureEngine?
    var demoStartTask: Task<Void, Never>?
    var demoFinalizationTask: Task<Bool, Never>?
    var demoRect: CGRect?
    var item: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var copyHotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var localKeyMonitor: Any?
    var isQuitting = false
    let logger = Logger(subsystem: "local.nic.Capture", category: "actions")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupMenu()
        setupHotKey()
        model.showPanel = { [weak self] in self?.showToolbar() }
        model.hidePanel = { [weak self] in self?.panel.orderOut(nil); self?.resultPanel.orderOut(nil) }
        model.showResult = { [weak self] in self?.showCaptureResult() }
        model.onFeedback = { [weak self] message in self?.showFeedback(message) }
        model.onRecordingChanged = { [weak self] recording in self?.updateMenu(recording: recording) }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard !self.isQuitting else { return nil }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == [.control, .command, .shift] {
                if event.keyCode == 23 { self.toggleToolbar(); return nil }
                if event.keyCode == 8 { self.performCopyShortcut(); return nil }
            }
            let resultVisible = self.resultPanel.isVisible
            guard !self.model.isSelectingArea, self.panel.isVisible || resultVisible else { return event }
            if event.keyCode == 53 {
                if resultVisible { self.model.dismissResult() } else { self.model.closeToolbar() }
                return nil
            }
            if modifiers == .command && event.keyCode == 12 {
                self.quitApp(); return nil
            }
            if modifiers == .command && event.keyCode == 8 {
                if resultVisible { self.model.copyLastCapture() }
                else if self.model.isRecording { self.model.stopAndCopyRecording() }
                else { self.model.copyScreenshot() }
                return nil
            }
            if modifiers == .command && event.keyCode == 15 && !resultVisible {
                self.model.toggleRecording(); return nil
            }
            if (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty {
                if resultVisible { self.model.openLastCapture() } else { self.model.captureScreenshot() }
                return nil
            }
            return event
        }
        if CommandLine.arguments.contains("--verify-engine") {
            Task { await runVerification() }
        } else {
            showToolbar()
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            model.refresh()
            if CommandLine.arguments.contains("--demo-output") { demoStartTask = Task { await startDemoRecording() } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.isSelectingArea { return true }
        if model.showingResult { showCaptureResult() } else { showToolbar() }
        model.refresh()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !model.isRecording && !model.isBusy { model.refresh() }
    }

    func setupPanel() {
        panel = ToolbarPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 116),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ToolbarView(model: model))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.setAccessibilityTitle("Capture toolbar")
        resultPanel = ToolbarPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        resultPanel.isFloatingPanel = true; resultPanel.level = .floating
        resultPanel.isOpaque = false; resultPanel.backgroundColor = .clear
        resultPanel.hasShadow = true; resultPanel.hidesOnDeactivate = false
        resultPanel.isMovableByWindowBackground = true
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let resultHost = NSHostingView(rootView: CaptureResultView(model: model))
        resultPanel.contentView = resultHost; resultPanel.setContentSize(NSSize(width: 480, height: 360))
        resultPanel.setAccessibilityTitle("Capture result")
        feedbackPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        feedbackPanel.isOpaque = false; feedbackPanel.backgroundColor = .clear
        feedbackPanel.level = .floating; feedbackPanel.hasShadow = false
        feedbackPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        feedbackPanel.hidesOnDeactivate = false
    }

    func showCaptureResult() {
        panel.orderOut(nil)
        position(resultPanel)
        resultPanel.orderFrontRegardless()
        resultPanel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showFeedback(_ message: String) {
        let text = Text(message).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.regularMaterial).clipShape(Capsule())
        let host = NSHostingView(rootView: text)
        feedbackPanel.contentView = host
        feedbackPanel.setContentSize(host.fittingSize)
        position(feedbackPanel)
        feedbackPanel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.feedbackPanel.orderOut(nil) }
    }

    func position(_ window: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main!
        let visible = screen.visibleFrame
        let size = window.frame.size
        if let demoRect {
            let globalTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? screen.frame.maxY
            window.setFrameOrigin(NSPoint(x: demoRect.midX - size.width / 2, y: globalTop - demoRect.maxY + 22))
        } else {
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 44))
        }
    }

    func setupMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Capture")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Capture   ⌃⌘⇧5", action: #selector(toggleToolbar), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.isHidden = true
        stop.tag = 10
        menu.addItem(stop)
        let copy = NSMenuItem(title: "Stop and Copy   ⌃⌘⇧C", action: #selector(stopAndCopy), keyEquivalent: "")
        copy.target = self; copy.tag = 11; copy.isHidden = true
        menu.addItem(copy)
        let latest = NSMenuItem(title: "Preview Last Capture", action: #selector(openLatest), keyEquivalent: "")
        latest.target = self
        menu.addItem(latest)
        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Capture", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func updateMenu(recording: Bool) {
        item.button?.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "viewfinder", accessibilityDescription: recording ? "Stop Capture recording" : "Capture")
        item.button?.contentTintColor = recording ? .systemRed : nil
        item.menu?.item(withTag: 10)?.isHidden = !recording
        item.menu?.item(withTag: 11)?.isHidden = !recording
        item.button?.toolTip = recording ? "Recording • ⌃⌘⇧5 to stop" : "Capture • ⌃⌘⇧5"
    }

    func showToolbar() {
        guard !model.isSelectingArea else { return }
        resultPanel.orderOut(nil)
        model.showingResult = false
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleToolbar() {
        guard !isQuitting else { return }
        if model.isSelectingArea { model.cancelSelection() }
        else if model.isRecording { model.toggleRecording() }
        else if resultPanel.isVisible { showToolbar(); model.refresh() }
        else if panel.isVisible { model.closeToolbar() }
        else { showToolbar(); model.refresh() }
    }
    @objc func stopRecording() { if !isQuitting { model.toggleRecording() } }
    @objc func stopAndCopy() { if !isQuitting { model.stopAndCopyRecording() } }
    func performCopyShortcut() {
        guard !isQuitting else { return }
        if model.isRecording { model.stopAndCopyRecording() }
        else if model.showingResult { model.copyLastCapture() }
        else { model.copyScreenshot() }
    }
    @objc func openLatest() { model.previewLastCapture() }
    @objc func openFolder() { model.openSaveFolder() }
    @objc func quitApp() {
        guard !isQuitting else { return }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        model.cancelSelection()
        panel.ignoresMouseEvents = true
        resultPanel.ignoresMouseEvents = true
        Task {
            let captureFinished = await model.prepareToQuit()
            // Keep capture controls disabled while the independent demo writer finishes.
            model.isBusy = true
            let demoFinished = await finalizeDemoRecording()
            model.isBusy = false
            isQuitting = false
            panel.ignoresMouseEvents = false
            resultPanel.ignoresMouseEvents = false
            sender.reply(toApplicationShouldTerminate: captureFinished && demoFinished)
        }
        return .terminateLater
    }

    func setupHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID(signature: 0, id: 0)
            if let event {
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            }
            let shortcutID = identifier.id
            Task { @MainActor in
                guard !app.isQuitting else { return }
                app.logger.info("Global shortcut received: \(shortcutID)")
                if shortcutID == 2 { app.performCopyShortcut() }
                else { app.toggleToolbar() }
            }
            return noErr
        }, 1, &spec, pointer, &handler)
        let identifier = EventHotKeyID(signature: OSType(0x43415054), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_5), UInt32(controlKey | cmdKey | shiftKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        let copyID = EventHotKeyID(signature: OSType(0x43415054), id: 2)
        let copyResult = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | cmdKey | shiftKey), copyID, GetApplicationEventTarget(), 0, &copyHotKey)
        logger.info("Copy shortcut registration \(copyResult)")
        logger.info("Shortcut handler \(installResult), registration \(result)")
        if result != noErr || installResult != noErr { model.status = "Shortcut is already used • Open Capture from the menu bar" }
        else if copyResult != noErr { model.status = "Copy shortcut is already used • Use ⌘C in Capture" }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let copyHotKey { UnregisterEventHotKey(copyHotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
