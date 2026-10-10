import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import OSLog

@MainActor
final class CaptureModel: ObservableObject {
    @Published var mode: CaptureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "Area") ?? .region {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captureMode") }
    }
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var elapsed = "00:00"
    @Published var audio: AudioSource = .system {
        didSet {
            let value: String
            switch audio {
            case .none: value = "off"
            case .system: value = "system"
            case .microphone: value = "microphone"
            case .application(let pid): value = applications.first(where: { $0.processID == pid })?.bundleIdentifier ?? "off"
            }
            UserDefaults.standard.set(value, forKey: "audioSource")
        }
    }
    @Published var options = CaptureOptions()
    @Published var delaySeconds = 0
    @Published var countdown: Int?
    @Published var showingResult = false
    @Published var isLastSaved = false
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var applications: [SCRunningApplication] = []
    @Published var microphoneDevices: [AVCaptureDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var selectedWindowID: CGWindowID = 0
    @Published var region: CGRect? {
        didSet {
            if let region {
                UserDefaults.standard.set([region.origin.x, region.origin.y, region.width, region.height], forKey: "captureArea")
                UserDefaults.standard.set(Int(selectedDisplayID), forKey: "areaDisplay")
            }
        }
    }
    @Published var status = "Choose an area • Return to capture • ⌘C to copy"
    @Published var lastSavedURL: URL?
    var lastCaptureIsVideo: Bool { lastSavedURL?.pathExtension == "mp4" }
    let engine = CaptureEngine()
    var showPanel: (() -> Void)?
    var hidePanel: (() -> Void)?
    var showResult: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onFeedback: ((String) -> Void)?
    private var overlay: SelectionOverlay?
    private var windowOverlay: WindowSelection?
    private var clock: Timer?
    private var startedAt: Date?
    private var pendingAction: (() -> Void)?
    private var actionTask: Task<Void, Never>?
    private var restoredPreferences = false
    private var recordingSaveFailed = false
    var isSelectingArea: Bool { overlay != nil || windowOverlay != nil }
    private let logger = Logger(subsystem: "local.nic.Capture", category: "capture")

    var saveFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("Captures", isDirectory: true)
    }
    var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("local.nic.Capture/Clipboard", isDirectory: true)
    }

    init() {
        engine.onFailure = { [weak self] message in
            guard let self else { return }
            self.clock?.invalidate()
            self.isRecording = false
            self.isBusy = false
            self.status = message
            self.onRecordingChanged?(false)
            self.recordingSaveFailed = self.engine.recoveredRecordingURL != nil
            if let recovered = self.engine.recoveredRecordingURL {
                self.lastSavedURL = recovered
                self.isLastSaved = false
                self.showingResult = true
                self.showResult?()
            } else {
                self.showPanel?()
            }
        }
        microphoneDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        cleanOldCache()
    }

    func refresh() {
        Task {
            do {
                let content = try await engine.catalog()
                displays = content.displays
                windows = content.windows.filter {
                    $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                    !($0.owningApplication?.applicationName ?? "").isEmpty &&
                    $0.frame.width > 50 && $0.frame.height > 50 && !($0.title ?? "").isEmpty
                }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                applications = content.applications.filter {
                    $0.processID != ProcessInfo.processInfo.processIdentifier && !$0.applicationName.isEmpty &&
                    NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
                }.sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
                if !displays.contains(where: { $0.displayID == selectedDisplayID }), let first = displays.first { selectedDisplayID = first.displayID; region = nil }
                if !windows.contains(where: { $0.windowID == selectedWindowID }) { selectedWindowID = windows.first?.windowID ?? 0 }
                if !restoredPreferences {
                    restoredPreferences = true
                    if let values = UserDefaults.standard.array(forKey: "captureArea") as? [Double], values.count == 4 {
                        let savedDisplay = CGDirectDisplayID(UserDefaults.standard.integer(forKey: "areaDisplay"))
                        if let display = displays.first(where: { $0.displayID == savedDisplay }) {
                            selectedDisplayID = savedDisplay
                            let saved = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).intersection(CGRect(origin: .zero, size: display.frame.size))
                            if !saved.isNull && saved.width >= 16 && saved.height >= 16 { region = saved }
                        }
                    }
                    let preference = UserDefaults.standard.string(forKey: "audioSource") ?? "system"
                    switch preference {
                    case "off": audio = .none
                    case "microphone": audio = .microphone
                    case "system": audio = .system
                    default:
                        if let application = applications.first(where: { $0.bundleIdentifier == preference }) {
                            audio = .application(application.processID)
                        } else {
                            audio = .none
                            status = "Saved audio app is not running • Choose a source"
                        }
                    }
                    if let quality = UserDefaults.standard.string(forKey: "quality").flatMap(CaptureQuality.init(rawValue:)) { options.quality = quality }
                }
            } catch { status = "Allow Capture in Privacy & Security → Screen & System Audio Recording" }
        }
    }

    func target() throws -> CaptureTarget {
        switch mode {
        case .display: return .display(selectedDisplayID)
        case .window:
            guard selectedWindowID != 0 else { throw UserError("Choose an open window first.") }
            return .window(selectedWindowID)
        case .region:
            guard let region else { throw UserError("Choose an area first.") }
            return .region(displayID: selectedDisplayID, rect: region)
        }
    }

    func chooseRegion() {
        guard !isBusy, !isRecording, !isSelectingArea else { return }
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = cursorScreen ?? NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selectedDisplayID
        } ?? NSScreen.main
        guard let screen else { status = "No display is connected"; return }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        if displayID != selectedDisplayID { selectedDisplayID = displayID; region = nil }
        hidePanel?()
        let selector = SelectionOverlay()
        overlay = selector
        selector.onCopy = { [weak self] result in
            guard let self else { return }
            self.overlay = nil
            self.pendingAction = nil
            self.region = result
            self.mode = .region
            self.copyScreenshot()
        }
        selector.onRecord = { [weak self] result in
            guard let self else { return }
            self.overlay = nil
            self.pendingAction = nil
            self.region = result
            self.mode = .region
            self.beginRecording()
        }
        selector.select(on: screen, initial: region) { [weak self] result in
            guard let self else { return }
            self.overlay = nil
            if let result {
                self.region = result
                self.mode = .region
                self.status = "\(Int(result.width)) × \(Int(result.height)) • Return to capture • ⌘C to copy"
                let action = self.pendingAction
                self.pendingAction = nil
                if let action { action() } else { self.captureScreenshot() }
            } else {
                self.pendingAction = nil
                self.status = "Selection cancelled"
                self.showPanel?()
            }
        }
    }

    private func makeURL(_ ext: String, temporary: Bool = false) throws -> URL {
        let folder = temporary ? cacheFolder : saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Capture \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4)).\(ext)")
    }

    private func beforeCapture() async throws {
        showingResult = false
        if delaySeconds > 0 {
            for value in stride(from: delaySeconds, through: 1, by: -1) {
                countdown = value
                status = "Starting in \(value)… • Esc to cancel"
                showPanel?()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        countdown = nil
        hidePanel?()
        try await Task.sleep(nanoseconds: 180_000_000)
        try Task.checkCancellation()
        UserDefaults.standard.set(options.quality.rawValue, forKey: "quality")
    }

    func captureScreenshot() { performScreenshot(copyOnly: false) }
    func copyScreenshot() {
        if let overlay { overlay.copySelection(); return }
        if let windowOverlay { windowOverlay.copySelection(); return }
        performScreenshot(copyOnly: true)
    }
    func cancelSelection() {
        overlay?.cancel()
        windowOverlay?.cancel()
    }

    func chooseWindow() {
        guard !isBusy, !isRecording, !isSelectingArea else { return }
        guard !windows.isEmpty else { status = "No open windows are available"; return }
        hidePanel?()
        let selector = WindowSelection()
        windowOverlay = selector
        selector.onCopy = { [weak self] identifier in
            guard let self else { return }
            self.windowOverlay = nil
            self.selectedWindowID = identifier
            self.mode = .window
            self.copyScreenshot()
        }
        selector.onRecord = { [weak self] identifier in
            guard let self else { return }
            self.windowOverlay = nil
            self.selectedWindowID = identifier
            self.mode = .window
            self.beginRecording()
        }
        selector.select(windows: windows) { [weak self] identifier in
            guard let self else { return }
            self.windowOverlay = nil
            if let identifier {
                self.selectedWindowID = identifier
                self.mode = .window
                self.status = "Window selected • Return to capture • ⌘C to copy"
                self.captureScreenshot()
            } else {
                self.showPanel?()
            }
        }
    }
    private func performScreenshot(copyOnly: Bool) {
        guard !isBusy, !isRecording, !isSelectingArea else { return }
        if mode == .region && region == nil {
            pendingAction = { [weak self] in self?.performScreenshot(copyOnly: copyOnly) }
            chooseRegion(); return
        }
        actionTask = Task {
            isBusy = true
            status = copyOnly ? "Copying screenshot…" : "Capturing screenshot…"
            do {
                let selected = try target()
                try await beforeCapture()
                if copyOnly {
                    let image = try await engine.screenshotImage(selected, options: options)
                    try copyImage(image)
                    status = "Screenshot copied"
                    logger.info("Screenshot copied without saving a file")
                    onFeedback?("Screenshot copied")
                } else {
                    let url = try makeURL("png")
                    try await engine.captureScreenshot(selected, to: url, options: options)
                    lastSavedURL = url; isLastSaved = true
                    status = "Screenshot saved"
                    showingResult = true; showResult?()
                }
            } catch is CancellationError {
                countdown = nil; status = "Capture cancelled"; showPanel?()
            } catch { status = error.localizedDescription; showPanel?() }
            isBusy = false
        }
    }

    private func copyImage(_ image: CGImage) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), let tiff = bitmap.tiffRepresentation else {
            throw UserError("The screenshot could not be copied.")
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else { throw UserError("The clipboard is unavailable.") }
    }

    func toggleRecording() {
        if isRecording { finishRecording(copyOnly: false) } else { beginRecording() }
    }
    private func beginRecording() {
        guard !isBusy, !isSelectingArea else { return }
        if mode == .region && region == nil {
            pendingAction = { [weak self] in self?.beginRecording() }
            chooseRegion(); return
        }
        actionTask = Task {
            isBusy = true
            status = "Preparing recording…"
            do {
                let wantsMic = audio == .microphone || (audio != .none && options.microphoneEnabled)
                if wantsMic && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    status = "Approve microphone access to record"
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw UserError("Allow microphone access in Privacy & Security → Microphone.") }
                }
                let selected = try target()
                let url = try makeURL("mp4", temporary: true)
                try await beforeCapture()
                try await engine.startRecording(selected, audio: audio, to: url, options: options)
                startedAt = Date(); elapsed = "00:00"; isRecording = true
                status = "Recording • ⌃⌘⇧5 to save • ⌃⌘⇧C to copy"
                onRecordingChanged?(true)
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let date = self.startedAt else { return }
                        let seconds = Int(Date().timeIntervalSince(date))
                        self.elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                    }
                }
            } catch is CancellationError {
                countdown = nil; status = "Recording cancelled"; showPanel?()
            } catch { status = error.localizedDescription; showPanel?() }
            isBusy = false
        }
    }

    func stopAndCopyRecording() { if isRecording { finishRecording(copyOnly: true) } }
    private func finishRecording(copyOnly: Bool) {
        guard !isBusy, isRecording else { return }
        actionTask = Task {
            isBusy = true; clock?.invalidate(); status = "Finishing recording…"
            recordingSaveFailed = false
            var completedURL: URL?
            do {
                let cached = try await engine.stopRecording()
                completedURL = cached
                lastSavedURL = cached; isLastSaved = false
                if copyOnly {
                    try copyFile(cached)
                    status = "Recording copied • Kept in temporary cache"
                    logger.info("Recording copied from cache without a Movies file")
                    onFeedback?("Recording copied")
                    hidePanel?()
                } else {
                    let saved = try makeURL("mp4")
                    try FileManager.default.moveItem(at: cached, to: saved)
                    lastSavedURL = saved; isLastSaved = true
                    status = "Recording saved"
                    showingResult = true; showResult?()
                }
            } catch {
                recordingSaveFailed = !copyOnly
                status = error.localizedDescription
                if completedURL == nil, let recovered = engine.recoveredRecordingURL {
                    completedURL = recovered
                    lastSavedURL = recovered; isLastSaved = false
                }
                if completedURL != nil { showingResult = true; showResult?() } else { showPanel?() }
            }
            isRecording = false; isBusy = false; onRecordingChanged?(false)
        }
    }

    func prepareToQuit() async -> Bool {
        if countdown != nil { actionTask?.cancel() }
        await actionTask?.value
        if isRecording {
            finishRecording(copyOnly: false)
            await actionTask?.value
        }
        return !recordingSaveFailed
    }

    private func copyFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw UserError("This capture is no longer available.") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([url as NSURL]) else { throw UserError("The clipboard is unavailable.") }
    }

    func copyLastCapture() {
        guard let url = lastSavedURL else { return }
        do {
            if lastCaptureIsVideo { try copyFile(url) }
            else {
                guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw UserError("The screenshot could not be opened.") }
                try copyImage(image)
            }
            status = lastCaptureIsVideo ? "Recording copied" : "Screenshot copied"
            onFeedback?(status)
        } catch { status = error.localizedDescription }
    }
    func openLastCapture() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.open(url)
    }
    func previewLastCapture() {
        guard lastSavedURL != nil else { onFeedback?("No capture yet"); return }
        showingResult = true
        showResult?()
    }
    func saveLastCapture() {
        guard let url = lastSavedURL, !isLastSaved else { return }
        do {
            let saved = try makeURL(url.pathExtension)
            // Keep cached source alive while the pasteboard may still reference it.
            try FileManager.default.copyItem(at: url, to: saved)
            lastSavedURL = saved; isLastSaved = true; recordingSaveFailed = false; status = "Capture saved"
        } catch { status = error.localizedDescription }
    }
    func dismissResult() { showingResult = false; hidePanel?() }
    func closeToolbar() {
        if let countdown, countdown > 0 { actionTask?.cancel(); self.countdown = nil }
        pendingAction = nil
        hidePanel?()
    }
    func revealLastCapture() {
        if let url = lastSavedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func openSaveFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }
    private func cleanOldCache() {
        let clipboardURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where !clipboardURLs.contains(file) {
            guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  Date().timeIntervalSince(created) > 7 * 24 * 3600 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct UserError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
