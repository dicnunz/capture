import AppKit
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable {
    case display = "Screen"
    case window = "Window"
    case region = "Area"
}

enum CaptureTarget {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(displayID: CGDirectDisplayID, rect: CGRect)
}

enum AudioSource: Hashable {
    case none
    case system
    case microphone
    case application(Int32)
}

enum CaptureQuality: String, CaseIterable, Codable {
    case compatible = "Compatible"
    case original = "High quality"
}

struct CaptureOptions {
    var quality: CaptureQuality = .original
    var showsCursor = true
    var showsClicks = false
    var microphoneDeviceID: String?
    var microphoneEnabled = false
    var includesCaptureUI = false
}
