import AppKit

@MainActor
final class SelectionOverlay {
    var onCopy: ((CGRect) -> Void)?
    var onRecord: ((CGRect) -> Void)?
    private var panel: SelectionPanel?
    private var completion: ((CGRect?) -> Void)?

    func cancel() {
        guard panel != nil else { return }
        finish(nil)
    }

    func copySelection() {
        guard onCopy != nil, let selection = (panel?.contentView as? RegionSelectionView)?.validSelection else { return }
        finishCopy(selection)
    }

    func select(on screen: NSScreen, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        if panel != nil { finish(nil) }
        self.completion = completion

        let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.selection = initial?.intersection(view.bounds)
        view.onFinish = { [weak self] rect in self?.finish(rect) }
        if onCopy != nil { view.onCopy = { [weak self] rect in self?.finishCopy(rect) } }
        if onRecord != nil { view.onRecord = { [weak self] rect in self?.finishRecord(rect) } }
        panel.contentView = view
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }

    private func finish(_ rect: CGRect?) {
        let callback = completion
        completion = nil
        close()
        DispatchQueue.main.async { callback?(rect) }
    }

    private func finishCopy(_ rect: CGRect) {
        let callback = onCopy
        completion = nil
        close()
        DispatchQueue.main.async { callback?(rect) }
    }

    private func finishRecord(_ rect: CGRect) {
        let callback = onRecord
        completion = nil
        close()
        DispatchQueue.main.async { callback?(rect) }
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        NSCursor.arrow.set()
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RegionSelectionView: NSView {
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            updateControls()
        }
    }
    var onFinish: ((CGRect?) -> Void)?
    var onCopy: ((CGRect) -> Void)? { didSet { updateControls() } }
    var onRecord: ((CGRect) -> Void)? { didSet { updateControls() } }
    private var previousSelection: CGRect?
    private var interaction: Interaction?
    private let controls = NSVisualEffectView()
    private let instruction = NSTextField(labelWithString: "Drag to select an area")
    private lazy var useButton = NSButton(title: "Capture", target: self, action: #selector(confirmSelection))
    private lazy var copyButton = NSButton(title: "Copy", target: self, action: #selector(copySelection))
    private lazy var recordButton = NSButton(title: "Record", target: self, action: #selector(recordSelection))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureControls()
    }

    private func configureControls() {
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.appearance = NSAppearance(named: .darkAqua)
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 12
        controls.layer?.masksToBounds = true
        controls.layer?.borderWidth = 0.5
        controls.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(controls)

        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel selection")!, target: self, action: #selector(cancelSelection))
        cancel.isBordered = false
        cancel.frame = CGRect(x: 12, y: 14, width: 24, height: 24)
        cancel.toolTip = "Cancel (Esc)"
        controls.addSubview(cancel)

        instruction.font = .systemFont(ofSize: 12, weight: .medium)
        instruction.textColor = .white
        instruction.frame = CGRect(x: 47, y: 17, width: 171, height: 18)
        controls.addSubview(instruction)

        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        copyButton.frame = CGRect(x: 224, y: 10, width: 72, height: 32)
        copyButton.toolTip = "Copy screenshot (⌘C)"
        controls.addSubview(copyButton)

        recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "r"
        recordButton.keyEquivalentModifierMask = .command
        recordButton.frame = CGRect(x: 304, y: 10, width: 84, height: 32)
        recordButton.toolTip = "Start recording this area (⌘R)"
        controls.addSubview(recordButton)

        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.keyEquivalentModifierMask = []
        useButton.frame = CGRect(x: 396, y: 10, width: 104, height: 32)
        useButton.toolTip = "Save screenshot (Return)"
        controls.addSubview(useButton)
        updateControls()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        controls.frame = CGRect(x: (bounds.width - 512) / 2, y: bounds.height - 90, width: 512, height: 52)
    }

    private func updateControls() {
        let valid = validSelection != nil
        instruction.stringValue = valid ? "Drag to move or resize" : "Drag to select an area"
        useButton.isEnabled = valid
        copyButton.isEnabled = valid && onCopy != nil
        recordButton.isEnabled = valid && onRecord != nil
    }

    var validSelection: CGRect? {
        guard let selection, selection.width >= 16, selection.height >= 16 else { return nil }
        return selection.integral.intersection(bounds)
    }

    @objc private func confirmSelection() {
        if let selection = validSelection { onFinish?(selection) }
    }

    @objc private func copySelection() {
        if let selection = validSelection { onCopy?(selection) }
    }

    @objc private func recordSelection() {
        if let selection = validSelection { onRecord?(selection) }
    }

    @objc private func cancelSelection() { onFinish?(nil) }

    private enum Interaction {
        case create(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, Handle)
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        var position: NSCursor.FrameResizePosition {
            switch self {
            case .topLeft: return .topLeft
            case .top: return .top
            case .topRight: return .topRight
            case .right: return .right
            case .bottomRight: return .bottomRight
            case .bottom: return .bottom
            case .bottomLeft: return .bottomLeft
            case .left: return .left
            }
        }

        var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        defer { addCursorRect(controls.frame, cursor: .arrow) }
        guard let selection, !selection.isEmpty else { return }
        addCursorRect(selection.insetBy(dx: 7, dy: 7), cursor: .openHand)
        addCursorRect(CGRect(x: selection.minX + 7, y: selection.minY - 7, width: max(0, selection.width - 14), height: 14), cursor: .frameResize(position: .top, directions: .all))
        addCursorRect(CGRect(x: selection.minX + 7, y: selection.maxY - 7, width: max(0, selection.width - 14), height: 14), cursor: .frameResize(position: .bottom, directions: .all))
        addCursorRect(CGRect(x: selection.minX - 7, y: selection.minY + 7, width: 14, height: max(0, selection.height - 14)), cursor: .frameResize(position: .left, directions: .all))
        addCursorRect(CGRect(x: selection.maxX - 7, y: selection.minY + 7, width: 14, height: max(0, selection.height - 14)), cursor: .frameResize(position: .right, directions: .all))
        for handle in Handle.allCases {
            let point = handle.point(in: selection)
            addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), cursor: .frameResize(position: handle.position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        previousSelection = selection
        let point = point(for: event)
        if event.clickCount == 2, selection?.contains(point) == true {
            confirmSelection()
            return
        }
        if let selection, let handle = handle(at: point, in: selection) {
            interaction = .resize(selection, handle)
        } else if let selection, selection.contains(point) {
            interaction = .move(selection, point)
            NSCursor.closedHand.set()
        } else {
            interaction = .create(point)
            selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = point(for: event)
        switch interaction {
        case .create(let anchor):
            selection = CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y), width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        case .move(let original, let anchor):
            selection = CGRect(x: min(max(original.minX + current.x - anchor.x, 0), bounds.width - original.width), y: min(max(original.minY + current.y - anchor.y, 0), bounds.height - original.height), width: original.width, height: original.height)
        case .resize(let original, let handle):
            var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
            if handle.movesLeft { left = min(current.x, right - 16) }
            if handle.movesRight { right = max(current.x, left + 16) }
            if handle.movesTop { top = min(current.y, bottom - 16) }
            if handle.movesBottom { bottom = max(current.y, top + 16) }
            selection = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        interaction = nil
        if validSelection == nil {
            selection = previousSelection
        } else {
            selection = validSelection
        }
        window?.invalidateCursorRects(for: self)
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        if let handle = Handle.allCases.first(where: {
            let center = $0.point(in: rect)
            return abs(point.x - center.x) <= 7 && abs(point.y - center.y) <= 7
        }) { return handle }
        if point.x >= rect.minX && point.x <= rect.maxX {
            if abs(point.y - rect.minY) <= 7 { return .top }
            if abs(point.y - rect.maxY) <= 7 { return .bottom }
        }
        if point.y >= rect.minY && point.y <= rect.maxY {
            if abs(point.x - rect.minX) <= 7 { return .left }
            if abs(point.x - rect.maxX) <= 7 { return .right }
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelection()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "r" {
            recordSelection()
            return
        }
        switch event.keyCode {
        case 53:
            cancelSelection()
        case 36, 76:
            confirmSelection()
        default:
            super.keyDown(with: event)
        }
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection, !selection.isEmpty {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        if let selection, !selection.isEmpty {
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            NSColor.white.setStroke()
            outline.stroke()

            for handle in Handle.allCases {
                let point = handle.point(in: selection)
                let box = NSBezierPath(roundedRect: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7), xRadius: 1, yRadius: 1)
                NSColor.white.setFill()
                box.fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                box.lineWidth = 0.75
                box.stroke()
            }

            let dimensions = "\(Int(selection.width)) × \(Int(selection.height))"
            let labelSize = (dimensions as NSString).size(withAttributes: labelAttributes)
            let label = CGRect(x: min(max(selection.midX - labelSize.width / 2 - 9, 8), bounds.width - labelSize.width - 26), y: max(8, selection.minY - 31), width: labelSize.width + 18, height: 24)
            drawLabel(dimensions, in: label)
        }

    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func drawLabel(_ text: String, in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let size = (text as NSString).size(withAttributes: labelAttributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: labelAttributes)
    }
}
