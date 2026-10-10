// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Capture",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Capture", targets: ["Capture"])],
    targets: [.executableTarget(name: "Capture", linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
        .linkedFramework("ScreenCaptureKit"), .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon")
    ])],
    swiftLanguageModes: [.v5]
)
