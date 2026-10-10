import AppKit
import ScreenCaptureKit

@MainActor
final class WindowSelection {
    var onRecord: ((CGWindowID) -> Void)?
    var onCopy: ((CGWindowID) -> Void)?
    private var panel: WindowSelectionPanel?
    private var completion: ((CGWindowID?) -> Void)?

    func select(windows: [SCWindow], completion: @escaping (CGWindowID?) -> Void) {
        cancel()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion(nil)
            return
        }
        let displayBounds = CGDisplayBounds(displayID.uint32Value)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let available = Dictionary(uniqueKeysWithValues: windows.filter {
            $0.isOnScreen && $0.owningApplication?.processID != ownProcess
        }.map { ($0.windowID, $0) })
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = ordered.compactMap { info -> WindowCandidate? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let window = available[number.uint32Value],
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { return nil }
            let frame: CGRect
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let current = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                frame = current
            } else { frame = window.frame }
            guard !frame.intersection(displayBounds).isEmpty else { return nil }
            let application = window.owningApplication?.applicationName ?? "Application"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WindowCandidate(id: window.windowID,
                                   frame: frame.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY),
                                   label: title.isEmpty ? application : "\(application): \(title)")
        }
        guard !candidates.isEmpty else { completion(nil); return }
        self.completion = completion

        let panel = WindowSelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityTitle("Choose a window to capture")
        let view = WindowSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), candidates: candidates)
        view.onFinish = { [weak self] identifier in self?.finish(identifier) }
        if onRecord != nil { view.onRecord = { [weak self] identifier in self?.finishRecording(identifier) } }
        if onCopy != nil { view.onCopy = { [weak self] identifier in self?.finishCopy(identifier) } }
        panel.contentView = view
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        let mouse = NSEvent.mouseLocation
        view.updateHover(at: CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y))
        NSCursor.pointingHand.set()
    }

    func cancel() {
        guard panel != nil else { return }
        finish(nil)
    }

    func copySelection() {
        guard onCopy != nil, let identifier = (panel?.contentView as? WindowSelectionView)?.hoveredIdentifier else { return }
        finishCopy(identifier)
    }

    private func finish(_ identifier: CGWindowID?) {
        let callback = completion
        completion = nil
        close()
        DispatchQueue.main.async { callback?(identifier) }
    }

    private func finishRecording(_ identifier: CGWindowID) {
        let callback = onRecord
        completion = nil
        close()
        DispatchQueue.main.async { callback?(identifier) }
    }

    private func finishCopy(_ identifier: CGWindowID) {
        let callback = onCopy
        completion = nil
        close()
        DispatchQueue.main.async { callback?(identifier) }
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        NSCursor.arrow.set()
    }
}

private struct WindowCandidate {
    let id: CGWindowID
    let frame: CGRect
    let label: String
}

private final class WindowSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class WindowSelectionView: NSView {
    var onFinish: ((CGWindowID?) -> Void)?
    var onRecord: ((CGWindowID) -> Void)?
    var onCopy: ((CGWindowID) -> Void)?
    private let candidates: [WindowCandidate]
    private var hovered: WindowCandidate?
    private var tracking: NSTrackingArea?
    private var windowButtons: [WindowCandidateAccessibilityButton] = []

    init(frame: CGRect, candidates: [WindowCandidate]) {
        self.candidates = candidates
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Click a window. Press Escape to cancel.")
        windowButtons = candidates.map { candidate in
            WindowCandidateAccessibilityButton(label: candidate.label, parent: self,
                frame: { [weak self] in
                    guard let self, let window = self.window else { return .zero }
                    return window.convertToScreen(self.convert(candidate.frame.intersection(self.bounds), to: nil))
                }, press: { [weak self] in
                    guard let callback = self?.onFinish else { return false }
                    callback(candidate.id)
                    return true
                })
        }
        setAccessibilityChildren(windowButtons)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var hoveredIdentifier: CGWindowID? { hovered?.id }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    func updateHover(at point: CGPoint) {
        let candidate = candidates.first { $0.frame.contains(point) }
        guard candidate?.id != hovered?.id else { return }
        hovered = candidate
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        if let hovered { onFinish?(hovered.id) }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c", let hovered {
            onCopy?(hovered.id)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "r", let hovered {
            onRecord?(hovered.id)
        } else if event.keyCode == 53 { onFinish?(nil) }
        else { super.keyDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let hovered {
            dim.append(NSBezierPath(rect: hovered.frame))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        dim.fill()
        if let hovered {
            let outline = NSBezierPath(rect: hovered.frame.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            NSColor.white.setStroke()
            outline.stroke()
        }
        var actions = ["Click to capture"]
        if onCopy != nil { actions.append("⌘C copy") }
        if onRecord != nil { actions.append("⌘R record") }
        actions.append("Esc cancel")
        let hint = actions.joined(separator: " • ") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attributes)
        let box = CGRect(x: (bounds.width - size.width - 28) / 2, y: bounds.height - 84, width: size.width + 28, height: 34)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        hint.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
    }
}

@MainActor
private final class WindowCandidateAccessibilityButton: NSAccessibilityElement {
    private let frameProvider: () -> NSRect
    private let press: () -> Bool

    init(label: String, parent: NSView, frame: @escaping () -> NSRect, press: @escaping () -> Bool) {
        frameProvider = frame
        self.press = press
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityEnabled(true)
        setAccessibilityHelp("Press to capture this window.")
    }

    override func accessibilityFrame() -> NSRect { frameProvider() }
    override func accessibilityPerformPress() -> Bool { press() }
}
