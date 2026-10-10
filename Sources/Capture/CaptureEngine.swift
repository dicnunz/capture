import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

private struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CaptureEngine: NSObject {
    var onFailure: ((String) -> Void)?
    private(set) var recoveredRecordingURL: URL?
    private var videoStream: SCStream?
    private var audioStream: SCStream?
    private var sink: RecordingSink?
    private var recordingURL: URL?

    func catalog(onScreenWindowsOnly: Bool = true) async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure(message: "Allow Capture in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Capture.")
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
    }

    func screenshotImage(_ target: CaptureTarget, options: CaptureOptions = .init()) async throws -> CGImage {
        let content = try await catalog(onScreenWindowsOnly: false)
        let (filter, configuration) = try makeCapture(target, content: content, recording: false, options: options)
        configuration.showsCursor = false
        if #available(macOS 26.0, *) {
            let screenshot = SCScreenshotConfiguration()
            screenshot.width = configuration.width
            screenshot.height = configuration.height
            screenshot.showsCursor = false
            screenshot.ignoreShadows = true
            screenshot.ignoreClipping = true
            screenshot.displayIntent = .local
            screenshot.dynamicRange = .sdr
            // Leave sourceRect unset for full-content capture instead of assigning the old configuration's
            // default zero rectangle to the newer API.
            if !configuration.sourceRect.isEmpty { screenshot.sourceRect = configuration.sourceRect }
            do {
                let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: screenshot)
                if let image = output.sdrImage { return image }
            } catch {
                // Keep capture usable on systems where the newer screenshot API rejects a valid filter.
                // The established API also retains the display color space when colorSpaceName is unset.
            }
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func captureScreenshot(_ target: CaptureTarget, to url: URL, options: CaptureOptions = .init()) async throws {
        let image = try await screenshotImage(target, options: options)
        try prepareDestination(url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureFailure(message: "Could not create the screenshot file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureFailure(message: "The screenshot could not be saved. Check available disk space.")
        }
    }

    func startRecording(_ target: CaptureTarget, audio: AudioSource, to url: URL, options: CaptureOptions = .init()) async throws {
        guard sink == nil else { throw CaptureFailure(message: "A recording is already running.") }
        recoveredRecordingURL = nil
        let capturesSystemAudio = audio != .none && audio != .microphone
        let capturesMicrophone = audio == .microphone || (capturesSystemAudio && options.microphoneEnabled)
        if capturesMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw CaptureFailure(message: "Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        if capturesMicrophone, let deviceID = options.microphoneDeviceID {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            guard devices.contains(where: { $0.uniqueID == deviceID && $0.isConnected }) else {
                throw CaptureFailure(message: "The selected microphone is disconnected. Choose another input.")
            }
        }
        let content = try await catalog(onScreenWindowsOnly: false)
        let (filter, configuration) = try makeCapture(target, content: content, recording: true, options: options)
        configuration.captureMicrophone = capturesMicrophone
        configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        try prepareDestination(url)
        let recorder = try RecordingSink(url: url, width: configuration.width, height: configuration.height,
                                         audio: capturesSystemAudio, microphone: capturesMicrophone, quality: options.quality)
        let screen = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        var sound: SCStream?
        var soundStarted = false
        do {
            try screen.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            if capturesMicrophone {
                try screen.addStreamOutput(recorder, type: .microphone, sampleHandlerQueue: recorder.queue)
            }
            if capturesSystemAudio {
                // Audio gets its own filter, so recording a window/region never changes the selected audio source.
                guard let display = content.displays.first else { throw CaptureFailure(message: "No display is available.") }
                let audioFilter: SCContentFilter
                if case .application(let processID) = audio {
                    guard let application = content.applications.first(where: { $0.processID == processID }),
                          processID != ProcessInfo.processInfo.processIdentifier || options.includesCaptureUI else {
                        throw CaptureFailure(message: "The selected audio app has closed. Choose it again.")
                    }
                    audioFilter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
                } else {
                    audioFilter = SCContentFilter(display: display, excludingApplications: excludedApplications(content, includesCaptureUI: options.includesCaptureUI), exceptingWindows: [])
                }
                let audioConfiguration = SCStreamConfiguration()
                audioConfiguration.width = 2
                audioConfiguration.height = 2
                audioConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                audioConfiguration.capturesAudio = true
                audioConfiguration.excludesCurrentProcessAudio = !options.includesCaptureUI
                audioConfiguration.sampleRate = 48_000
                audioConfiguration.channelCount = 2
                let soundStream = SCStream(filter: audioFilter, configuration: audioConfiguration, delegate: recorder)
                try soundStream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
                sound = soundStream
            }
            sink = recorder
            videoStream = screen
            audioStream = sound
            recordingURL = url
            recorder.failure = { [weak self, weak recorder] message in
                Task { @MainActor in
                    guard let self, let recorder, self.sink === recorder else { return }
                    var failureMessage = message
                    do { self.recoveredRecordingURL = try await self.stopRecording() }
                    catch { failureMessage += " \(error.localizedDescription)" }
                    self.onFailure?(failureMessage)
                }
            }
            if let sound {
                try await sound.startCapture()
                soundStarted = true
            }
            try await screen.startCapture()
        } catch {
            try? await screen.stopCapture()
            if soundStarted { try? await sound?.stopCapture() }
            await recorder.cancel()
            sink = nil
            videoStream = nil
            audioStream = nil
            recordingURL = nil
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        guard let recorder = sink, let url = recordingURL else {
            throw CaptureFailure(message: "No recording is running.")
        }
        let screen = videoStream
        let sound = audioStream
        // Detach before suspension to make repeated stop requests safe.
        sink = nil
        videoStream = nil
        audioStream = nil
        recordingURL = nil
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let sound { try? await sound.stopCapture() }
        if let screen { try? await screen.stopCapture() }
        do { try await recorder.finish(at: stopTime) }
        catch {
            if let recovered = recorder.finalizedRecordingURL, FileManager.default.fileExists(atPath: recovered.path) {
                recoveredRecordingURL = recovered
            }
            throw error
        }
        return url
    }

    private func prepareDestination(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureFailure(message: "A file with that name already exists.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func excludedApplications(_ content: SCShareableContent, includesCaptureUI: Bool) -> [SCRunningApplication] {
        content.applications.filter {
            ($0.processID == ProcessInfo.processInfo.processIdentifier && !includesCaptureUI) ||
            ["com.apple.systemuiserver", "com.apple.controlcenter"].contains($0.bundleIdentifier)
        }
    }

    private func isCaptureApplication(_ application: SCRunningApplication) -> Bool {
        if application.processID == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        return application.bundleIdentifier == bundleIdentifier
    }

    private func captureApplications(_ content: SCShareableContent) -> [SCRunningApplication] {
        // Accessory apps may be absent from applications while their panels still have an owner.
        var seen = Set<pid_t>()
        return (content.applications + content.windows.compactMap(\.owningApplication)).filter {
            isCaptureApplication($0) && seen.insert($0.processID).inserted
        }
    }

    private func makeCapture(_ target: CaptureTarget, content: SCShareableContent, recording: Bool, options: CaptureOptions) throws -> (SCContentFilter, SCStreamConfiguration) {
        let filter: SCContentFilter
        let size: CGSize
        var crop: CGRect?
        switch target {
        case .display(let displayID), .region(let displayID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureFailure(message: "The selected display is no longer connected.")
            }
            let ownApps = options.includesCaptureUI ? [] : captureApplications(content)
            let excludedProcesses = Set(ownApps.map(\.processID))
            let nativeWindowIDs = Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
            let uncoveredWindows = options.includesCaptureUI ? [] : content.windows.filter { window in
                let isOwnWindow = nativeWindowIDs.contains(window.windowID) || window.owningApplication.map(isCaptureApplication) == true
                // Exceptions to an excluded application would include its windows again.
                return isOwnWindow && !excludedProcesses.contains(window.owningApplication?.processID ?? -1)
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: uncoveredWindows)
            filter.includeMenuBar = true
            if case .region(_, let rectangle) = target {
                let bounded = rectangle.standardized.intersection(CGRect(origin: .zero, size: display.frame.size))
                guard !bounded.isNull, bounded.width >= 2, bounded.height >= 2 else {
                    throw CaptureFailure(message: "Select a larger area inside one display.")
                }
                crop = bounded
                size = bounded.size
            } else {
                size = display.frame.size
            }
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier || options.includesCaptureUI else {
                throw CaptureFailure(message: "The selected window is no longer available.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = filter.contentRect.size
        }
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let width = max(2, Int((size.width * scale).rounded()))
        let height = max(2, Int((size.height * scale).rounded()))
        let configuration = SCStreamConfiguration()
        // 4:2:0 encoders require even dimensions. Pad odd edges instead of scaling away native pixels.
        configuration.width = recording ? (width + 1) / 2 * 2 : width
        configuration.height = recording ? (height + 1) / 2 * 2 : height
        if recording {
            configuration.destinationRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: options.quality == .original ? 60 : 30)
        configuration.queueDepth = 5
        configuration.showsCursor = options.showsCursor
        configuration.showMouseClicks = recording && options.showsClicks
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = !options.includesCaptureUI
        if let crop { configuration.sourceRect = crop }
        return (filter, configuration)
    }
}

private final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Capture.recording", qos: .userInitiated)
    var failure: ((String) -> Void)?
    // Read only after finish() returns or throws, when finalization has completed.
    private(set) var finalizedRecordingURL: URL?
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let microphoneAudio: AVAssetWriterInput?
    private let url: URL
    private let frameDuration: CMTime
    private var origin: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var bufferedAudio: [(CMSampleBuffer, SCStreamOutputType)] = []
    private var stopped = false
    private var failureReported = false

    init(url: URL, width: Int, height: Int, audio hasAudio: Bool, microphone: Bool, quality: CaptureQuality) throws {
        self.url = url
        let original = quality == .original
        let frameRate = original ? 60 : 30
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: original ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_AverageBitRate as String: max(8_000_000, width * height * (original ? 6 : 5)),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: original ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CaptureFailure(message: "This Mac cannot encode the selected native resolution with \(quality.rawValue) quality. Choose the other quality or a smaller capture area.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        if hasAudio {
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000
            ])
            audio?.expectsMediaDataInRealTime = true
        } else { audio = nil }
        if microphone {
            microphoneAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000
            ])
            microphoneAudio?.expectsMediaDataInRealTime = true
        } else { microphoneAudio = nil }
        super.init()
        guard writer.canAdd(video) else { throw CaptureFailure(message: "The video encoder is unavailable.") }
        writer.add(video)
        if let audio {
            guard writer.canAdd(audio) else { throw CaptureFailure(message: "The audio encoder is unavailable.") }
            writer.add(audio)
        }
        if let microphoneAudio {
            guard writer.canAdd(microphoneAudio) else { throw CaptureFailure(message: "The microphone encoder is unavailable.") }
            writer.add(microphoneAudio)
        }
        guard writer.startWriting() else {
            let error = writer.error ?? CaptureFailure(message: "Recording could not start.")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if origin == nil {
                origin = pts
                writer.startSession(atSourceTime: pts)
            }
            if video.isReadyForMoreMediaData {
                guard video.append(sampleBuffer) else { reportWriterFailure(); return }
                lastVideo = sampleBuffer
            }
            if !bufferedAudio.isEmpty {
                for (buffer, type) in bufferedAudio { appendAudio(buffer, type: type) }
                bufferedAudio.removeAll(keepingCapacity: true)
            }
        } else if type == .audio || type == .microphone {
            if origin == nil {
                bufferedAudio.append((sampleBuffer, type))
                if bufferedAudio.count > 120 { bufferedAudio.removeFirst() }
            } else { appendAudio(sampleBuffer, type: type) }
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        let input = type == .microphone ? microphoneAudio : audio
        guard let input, let origin, CMSampleBufferGetPresentationTimeStamp(sample) >= origin else { return }
        if input.isReadyForMoreMediaData, !input.append(sample) { reportWriterFailure() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.report(error.localizedDescription) }
    }

    private func reportWriterFailure() {
        report(writer.error?.localizedDescription ?? "The recording could not be written. Check available disk space.")
    }

    private func report(_ message: String) {
        guard !stopped, !failureReported else { return }
        failureReported = true
        failure?(message)
    }

    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopped = true
                self.writer.cancelWriting()
                self.lastVideo = nil
                self.bufferedAudio.removeAll()
                try? FileManager.default.removeItem(at: self.url)
                continuation.resume()
            }
        }
    }

    func finish(at endTime: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.stopped else { continuation.resume(throwing: CaptureFailure(message: "Recording already ended.")); return }
                self.stopped = true
                guard let origin = self.origin, let last = self.lastVideo, self.writer.status == .writing else {
                    let error = self.writer.error ?? CaptureFailure(message: "No screen frames were captured. Check screen recording permission and try again.")
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    continuation.resume(throwing: error)
                    return
                }
                // Static screens emit no new frames. Repeat the last image at stop time to retain the full duration.
                let finalTime = max(endTime, origin + self.frameDuration)
                let lastTime = CMSampleBufferGetPresentationTimeStamp(last)
                if finalTime > lastTime, self.video.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: self.frameDuration, presentationTimeStamp: finalTime, decodeTimeStamp: .invalid)
                    var extended: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &extended) == noErr,
                       let extended { _ = self.video.append(extended) }
                }
                self.writer.endSession(atSourceTime: finalTime)
                self.video.markAsFinished()
                self.audio?.markAsFinished()
                self.microphoneAudio?.markAsFinished()
                self.lastVideo = nil
                self.bufferedAudio.removeAll()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        self.finalizedRecordingURL = self.url
                        continuation.resume()
                    } else {
                        let error = self.writer.error ?? CaptureFailure(message: "The recording could not be saved.")
                        try? FileManager.default.removeItem(at: self.url)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        if audio != nil, microphoneAudio != nil {
            do { try await Self.mixAudioTracks(at: url) }
            catch {
                throw CaptureFailure(message: "Video saved to \(url.path) with separate audio tracks, but the microphone and app audio could not be combined: \(error.localizedDescription)")
            }
        }
    }

    private static func mixAudioTracks(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let videoFormat = try await videoTrack.load(.formatDescriptions).first else {
            throw CaptureFailure(message: "The captured video track is missing.")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".capture-mix-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try AVAssetReader(asset: asset)
        let pictureOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        pictureOutput.alwaysCopiesSampleData = false
        let soundOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        soundOutput.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let pictureInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        pictureInput.transform = try await videoTrack.load(.preferredTransform)
        let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000
        ])
        let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(pictureOutput, pictureInput), (soundOutput, soundInput)]
        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw CaptureFailure(message: "The audio mixer is unavailable.")
            }
            reader.add(output)
            writer.add(input)
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CaptureFailure(message: "The audio mixer could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        try await AudioMixTransfer(reader: reader, writer: writer, pairs: pairs).run()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

// AVFoundation marks these objects non-Sendable. All mutable transfer work belongs to this one serial queue.
private final class AudioMixTransfer: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
    private let queue = DispatchQueue(label: "Capture.audioMix", qos: .userInitiated)
    private var finished = Set<Int>()
    private var ended = false

    init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader
        self.writer = writer
        self.pairs = pairs
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            for index in pairs.indices {
                pairs[index].1.requestMediaDataWhenReady(on: queue) { [self] in
                    drain(index, continuation: continuation)
                }
            }
        }
    }

    private func drain(_ index: Int, continuation: CheckedContinuation<Void, Error>) {
        guard !ended, !finished.contains(index) else { return }
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    fail(reader.error ?? CaptureFailure(message: "Captured audio could not be read."), continuation: continuation)
                    return
                }
                input.markAsFinished()
                finished.insert(index)
                break
            }
            guard input.append(sample) else {
                fail(writer.error ?? CaptureFailure(message: "Mixed audio could not be written."), continuation: continuation)
                return
            }
        }
        if finished.count == pairs.count {
            ended = true
            writer.finishWriting { [self] in
                if writer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: writer.error ?? CaptureFailure(message: "Mixed audio could not be saved.")) }
            }
        }
    }

    private func fail(_ error: Error, continuation: CheckedContinuation<Void, Error>) {
        guard !ended else { return }
        ended = true
        reader.cancelReading()
        writer.cancelWriting()
        continuation.resume(throwing: error)
    }
}
