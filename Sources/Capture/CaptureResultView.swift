import AppKit
import AVKit
import SwiftUI

struct CaptureResultView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: model.dismissResult) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close capture preview")
                .help("Close preview (Esc)")
            }

            preview
                .frame(width: 452, height: 254)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onDrag {
                    guard let url = model.lastSavedURL else { return NSItemProvider() }
                    return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
                }
                .help("Drag this capture into another app")

            HStack(spacing: 9) {
                Text(model.status.localizedCaseInsensitiveContains("copied") ? "Copied · ⌘V to paste" : (model.lastCaptureIsVideo ? "Drag video to another app" : "Drag image or copy to paste"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Copy", action: model.copyLastCapture)
                    .keyboardShortcut("c", modifiers: .command)
                    .help(model.lastCaptureIsVideo ? "Copy video file (⌘C)" : "Copy image (⌘C)")
                if model.isLastSaved {
                    Button("Reveal", action: model.revealLastCapture)
                        .help("Show this capture in Finder")
                } else {
                    Button("Save", action: model.saveLastCapture)
                        .help("Save this capture")
                }
                Button("Open", action: model.openLastCapture)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Open this capture (Return)")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.lastSavedURL == nil || model.isBusy)
        }
        .padding(14)
        .frame(width: 480, height: 360)
        .background(CapturePanelMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
        }
        .onExitCommand(perform: model.dismissResult)
    }

    private var title: String {
        let kind = model.lastCaptureIsVideo ? "Recording" : "Screenshot"
        return "\(kind) \(model.isLastSaved ? "saved" : "ready")"
    }

    @ViewBuilder private var preview: some View {
        if let url = model.lastSavedURL {
            if model.lastCaptureIsVideo {
                CaptureVideoPreview(url: url)
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityLabel("Screenshot preview")
            } else {
                Text("Preview unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CaptureVideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let currentURL = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url { view.player = AVPlayer(url: url) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
