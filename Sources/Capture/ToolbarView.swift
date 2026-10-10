import AppKit
import ScreenCaptureKit
import SwiftUI

struct ToolbarView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: model.closeToolbar) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close capture toolbar (Escape)")
                .accessibilityLabel("Close capture toolbar")

                HStack(spacing: 4) {
                    modeButton(.display, title: "Screen", symbol: "display")
                    modeButton(.window, title: "Window", symbol: "macwindow")
                    modeButton(.region, title: "Area", symbol: "viewfinder")
                }
                .disabled(model.isRecording || model.isBusy)

                Divider().frame(height: 36)

                VStack(alignment: .leading, spacing: 7) {
                    targetControl
                    audioControl
                }
                .frame(width: 167, alignment: .leading)
                .disabled(model.isRecording || model.isBusy)

                Spacer(minLength: 0)

                if model.isRecording {
                    Button(action: model.stopAndCopyRecording) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 78, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(model.isBusy)
                    .help("Stop recording and copy the video file (⌘C)")
                } else {
                    Button(action: model.captureScreenshot) {
                        Label("Capture", systemImage: "camera")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 78, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.isBusy)
                    .help("Save screenshot (Return) · Copy with ⌘C")
                }

                Button(action: model.toggleRecording) {
                    Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 76, height: 32)
                }
                .buttonStyle(.bordered)
                .tint(model.isRecording ? .red : .accentColor)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
                .help(model.isRecording ? "Stop and save (⌘R)" : "Start recording (⌘R)")
            }

            HStack(spacing: 7) {
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                } else if model.isRecording {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(model.elapsed).monospacedDigit().foregroundStyle(.primary)
                }

                Text(model.countdown.map { "Capturing in \($0)…" } ?? model.status)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                optionsControl
                    .disabled(model.isBusy || model.isRecording)
            }
            .font(.system(size: 11))
            .frame(height: 15)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 704)
        .background(CapturePanelMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
        }
        .onExitCommand(perform: model.closeToolbar)
    }

    private func modeButton(_ mode: CaptureMode, title: String, symbol: String) -> some View {
        Button {
            model.mode = mode
            if mode == .window { model.chooseWindow() }
            else if mode == .region && model.region == nil { model.chooseRegion() }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .frame(height: 22)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 49, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                if model.mode == mode {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.mode == mode ? .primary : .secondary)
        .accessibilityLabel("Capture \(title.lowercased())")
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
        .help("Capture \(title.lowercased())")
    }

    @ViewBuilder private var targetControl: some View {
        switch model.mode {
        case .display:
            Menu {
                ForEach(model.displays, id: \.displayID) { display in
                    Button {
                        model.selectedDisplayID = display.displayID
                    } label: {
                        checkedLabel(displayName(display.displayID), checked: model.selectedDisplayID == display.displayID)
                    }
                }
            } label: {
                menuLabel(displayName(model.selectedDisplayID), symbol: "display")
            }
            .menuStyle(.borderlessButton)
            .help("Choose the display to capture")
        case .window:
            Button(action: model.chooseWindow) {
                menuLabel(model.windows.first(where: { $0.windowID == model.selectedWindowID }).map { "\(windowName($0)) · Change" } ?? "Choose a window", symbol: "macwindow", chevron: false)
            }
            .buttonStyle(.plain)
            .help("Click a window to capture")
        case .region:
            Button(action: model.chooseRegion) {
                menuLabel(model.region.map { "\(Int($0.width)) × \(Int($0.height)) · Change" } ?? "Select an area", symbol: "viewfinder", chevron: false)
            }
            .buttonStyle(.plain)
            .help("Drag to select a capture area")
        }
    }

    private var audioControl: some View {
        Menu {
            audioOption("Off", value: .none)
            audioOption("System audio", value: .system)
            audioOption("Microphone only", value: .microphone)
            if !model.applications.isEmpty {
                Divider()
                Section("One app · all windows and tabs") {
                    ForEach(model.applications, id: \.processID) { application in
                        audioOption(shortened(application.applicationName), value: .application(application.processID))
                    }
                }
            }
            Divider()
            if canAddMicrophone {
                Toggle("Add microphone", isOn: $model.options.microphoneEnabled)
            }
            Menu("Microphone input") {
                Button {
                    model.options.microphoneDeviceID = nil
                } label: {
                    checkedLabel("System default", checked: model.options.microphoneDeviceID == nil)
                }
                ForEach(model.microphoneDevices, id: \.uniqueID) { device in
                    Button {
                        model.options.microphoneDeviceID = device.uniqueID
                    } label: {
                        checkedLabel(shortened(device.localizedName), checked: model.options.microphoneDeviceID == device.uniqueID)
                    }
                }
            }
        } label: {
            menuLabel(audioName, symbol: model.audio == .none ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .help("Choose system audio, a microphone, or one app. App audio includes all its windows and tabs.")
        .accessibilityLabel("Recording audio: \(audioName)")
    }

    private var optionsControl: some View {
        Menu {
            Section("Screenshot") {
                Button("Copy screenshot", action: model.copyScreenshot)
                    .keyboardShortcut("c", modifiers: .command)
                Picker("Delay", selection: $model.delaySeconds) {
                    Text("No delay").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Divider()
            Section("Capture") {
                Toggle("Show cursor", isOn: $model.options.showsCursor)
                Toggle("Show clicks in recordings", isOn: $model.options.showsClicks)
                Picker("Video quality", selection: $model.options.quality) {
                    Text("High quality · 60 fps").tag(CaptureQuality.original)
                    Text("Compatible · 30 fps").tag(CaptureQuality.compatible)
                }
            }
            Divider()
            Button("Open capture folder", action: model.openSaveFolder)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Capture delay, cursor and video quality")
    }

    private var canAddMicrophone: Bool {
        switch model.audio {
        case .system, .application: return true
        case .none, .microphone: return false
        }
    }

    private func audioOption(_ title: String, value: AudioSource) -> some View {
        Button { model.audio = value } label: {
            checkedLabel(title, checked: model.audio == value)
        }
    }

    private func checkedLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked { Image(systemName: "checkmark") }
        }
    }

    private func menuLabel(_ title: String, symbol: String, chevron: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14)
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .font(.system(size: 11, weight: .medium))
        .contentShape(Rectangle())
    }

    private var audioName: String {
        switch model.audio {
        case .none: return "Audio off"
        case .system: return "System audio" + (model.options.microphoneEnabled ? " + mic" : "")
        case .microphone: return "Microphone only"
        case .application(let pid):
            return "App: " + (model.applications.first(where: { $0.processID == pid })?.applicationName ?? "Selected app") + (model.options.microphoneEnabled ? " + mic" : "")
        }
    }

    private func displayName(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })?.localizedName ?? "Display"
    }

    private func windowName(_ window: SCWindow) -> String {
        let owner = window.owningApplication?.applicationName ?? "Window"
        guard let title = window.title, !title.isEmpty else { return shortened(owner) }
        return shortened("\(owner): \(title)")
    }

    private func shortened(_ text: String) -> String {
        text.count > 30 ? String(text.prefix(27)) + "…" : text
    }
}

struct CapturePanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
