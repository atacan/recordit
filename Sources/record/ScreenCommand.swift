import ArgumentParser
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct ScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Record the primary display to a temporary file.")

    enum VideoCodec: String, CaseIterable, ExpressibleByArgument {
        case h264
        case hevc
        case prores

        var avType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .prores: return .proRes422
            }
        }

        var fileType: AVFileType {
            switch self {
            case .prores:
                return .mov
            case .h264, .hevc:
                return .mp4
            }
        }
    }

    enum ScreenAudio: String, CaseIterable, ExpressibleByArgument {
        case none
        case system
        case mic
        case both
    }

    enum ScreenshotFormat {
        case png
        case jpeg
        case heic

        var name: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpeg"
            case .heic: return "heic"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            }
        }

        var utType: CFString {
            switch self {
            case .png: return UTType.png.identifier as CFString
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .heic: return UTType.heic.identifier as CFString
            }
        }

        static func fromExtension(_ value: String) -> ScreenshotFormat? {
            switch value.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "heic": return .heic
            default: return nil
            }
        }
    }

    @Option(help: "Stop recording after this many seconds. If omitted, press Ctrl-C to stop.")
    var duration: Double?

    @Option(help: "Write output to this file or directory. Default: temporary directory.")
    var output: String?

    @Option(help: "Filename pattern when output is a directory. Supports strftime tokens, {uuid}, and {chunk}.")
    var name: String?

    @Flag(help: "Overwrite output file if it exists.")
    var overwrite = false

    @Flag(help: "List available displays and exit.")
    var listDisplays = false

    @Flag(help: "List available windows and exit.")
    var listWindows = false

    @Flag(help: "Print machine-readable JSON to stdout.")
    var json = false

    @Flag(help: "Capture a single screenshot instead of a video recording.")
    var screenshot = false

    @Option(help: "Display ID to record, or 'primary'.")
    var display: String?

    @Option(help: "Window ID or title substring to record.")
    var window: String?

    @Option(help: "Stop key (single ASCII character). Default: s.")
    var stopKey: String?

    @Option(help: "Pause key (single ASCII character). Default: p. If same as resume key, toggles pause/resume.")
    var pauseKey: String?

    @Option(help: "Resume key (single ASCII character). Default: r. If same as pause key, toggles pause/resume.")
    var resumeKey: String?

    @Option(help: "Stop when output file reaches this size in MB.")
    var maxSizeMB: Double?

    @Option(help: "Split recording into chunks of this many seconds. Output must be a directory.")
    var split: Double?

    @Option(help: "Frames per second. Default: 30.")
    var fps: Double?

    @Option(help: "Video codec. Default: h264.")
    var codec: VideoCodec?

    @Option(help: "Video bit rate in bps (applies to h264/hevc).")
    var bitRate: Int?

    @Option(help: "Scale factor (e.g. 0.5 for half size). Default: 1.")
    var scale: Double?

    @Flag(help: "Hide the cursor in the recording.")
    var hideCursor = false

    @Flag(help: "Show mouse click highlights.")
    var showClicks = false

    @Option(help: "Capture region as x,y,w,h. Values may be pixels, 0..1 fractions, or percentages (e.g. 10%,10%,80%,80%).")
    var region: String?

    @Option(help: "Audio capture: none, system, mic, or both. Default: none.")
    var audio: ScreenAudio?

    @Option(help: "Audio sample rate. Default: 48000.")
    var audioSampleRate: Int?

    @Option(help: "Audio channel count. Default: 2.")
    var audioChannels: Int?

    @Option(name: .customLong("system-gain"), help: "Gain multiplier for system audio when using --audio system|both. Default: 1.0.")
    var systemGain: Double?

    mutating func run() async throws {
        ensureWindowServerConnection()
        guard requestScreenRecordingPermission() else {
            log("""
            Screen Recording permission not granted.

            Enable it in:
              System Settings → Privacy & Security → Screen Recording → (Terminal / iTerm / your terminal)
            """)
            throw ExitCode(2)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        if listDisplays {
            let displays = content.displays
            if json {
                struct RectInfo: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
                struct DisplayInfo: Codable { let id: UInt32; let width: Int; let height: Int; let frame: RectInfo }
                let out = displays.map {
                    DisplayInfo(
                        id: $0.displayID,
                        width: $0.width,
                        height: $0.height,
                        frame: RectInfo(
                            x: $0.frame.origin.x,
                            y: $0.frame.origin.y,
                            width: $0.frame.size.width,
                            height: $0.frame.size.height
                        )
                    )
                }
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for display in displays {
                    print("\(display.displayID)\t\(display.width)x\(display.height)\t\(display.frame)")
                }
            }
            return
        }

        if listWindows {
            let windows = content.windows
            if json {
                struct RectInfo: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
                struct WindowInfo: Codable {
                    let id: UInt32
                    let title: String?
                    let app: String?
                    let pid: Int32?
                    let layer: Int
                    let onScreen: Bool
                    let active: Bool?
                    let frame: RectInfo
                }
                let out = windows.map {
                    WindowInfo(
                        id: $0.windowID,
                        title: $0.title,
                        app: $0.owningApplication?.applicationName,
                        pid: $0.owningApplication?.processID,
                        layer: $0.windowLayer,
                        onScreen: $0.isOnScreen,
                        active: $0.isActive,
                        frame: RectInfo(
                            x: $0.frame.origin.x,
                            y: $0.frame.origin.y,
                            width: $0.frame.size.width,
                            height: $0.frame.size.height
                        )
                    )
                }
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for window in windows {
                    let title = window.title ?? "(untitled)"
                    let app = window.owningApplication?.applicationName ?? "(unknown)"
                    let activeFlag = window.isActive ? "*" : " "
                    let onScreenFlag = window.isOnScreen ? "on" : "off"
                    print("\(activeFlag) \(window.windowID)\t\(app)\t\(title)\t\(onScreenFlag)")
                }
            }
            return
        }

        let chosenWindow: SCWindow?
        if let window {
            let query = window.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw ValidationError("Window selector cannot be empty.")
            }
            if let windowID = UInt32(query) {
                guard let resolved = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw ValidationError("No window with ID \(windowID). Use --list-windows to see available windows.")
                }
                chosenWindow = resolved
            } else {
                let matches = matchingWindows(content.windows, query: query)
                if matches.count == 1 {
                    chosenWindow = matches.first
                } else if matches.isEmpty {
                    throw ValidationError("No window matches '\(window)'. Use --list-windows to see available windows.")
                } else if let resolved = resolveWindowMatch(matches, query: query) {
                    chosenWindow = resolved
                } else {
                    let names = matches.map(windowLabel).joined(separator: ", ")
                    throw ValidationError("Multiple windows match '\(window)': \(names). Please be more specific or use --window <id>.")
                }
            }
        } else {
            chosenWindow = nil
        }

        let chosenDisplay: SCDisplay?
        if chosenWindow != nil {
            chosenDisplay = nil
        } else if let display {
            if display.lowercased() == "primary" {
                chosenDisplay = content.displays.first
            } else if let displayID = UInt32(display) {
                chosenDisplay = content.displays.first { $0.displayID == displayID }
            } else {
                throw ValidationError("Invalid display '\(display)'. Use a display ID or 'primary'.")
            }
        } else {
            chosenDisplay = content.displays.first
        }

        if chosenWindow == nil, chosenDisplay == nil {
            log("No displays available for capture.")
            throw ExitCode(2)
        }

        if screenshot {
            if duration != nil {
                throw ValidationError("--duration is only supported for video recording.")
            }
            if split != nil {
                throw ValidationError("--split is only supported for video recording.")
            }
            if maxSizeMB != nil {
                throw ValidationError("--max-size is only supported for video recording.")
            }
            if stopKey != nil || pauseKey != nil || resumeKey != nil {
                throw ValidationError("Stop/pause/resume keys are only supported for video recording.")
            }
            if fps != nil {
                throw ValidationError("--fps is only supported for video recording.")
            }
            if codec != nil {
                throw ValidationError("--codec is only supported for video recording.")
            }
            if bitRate != nil {
                throw ValidationError("--bit-rate is only supported for video recording.")
            }
            if audio != nil || audioSampleRate != nil || audioChannels != nil {
                throw ValidationError("Audio capture options are only supported for video recording.")
            }
        } else {
            if let duration, duration <= 0 {
                throw ValidationError("Duration must be greater than 0 seconds.")
            }
            if let split, split <= 0 {
                throw ValidationError("Split duration must be greater than 0 seconds.")
            }
            if let maxSizeMB, maxSizeMB <= 0 {
                throw ValidationError("Max size must be greater than 0 MB.")
            }
            if let fps, fps <= 0 {
                throw ValidationError("FPS must be greater than 0.")
            }
            if let scale, scale <= 0 {
                throw ValidationError("Scale must be greater than 0.")
            }
            if let bitRate, bitRate <= 0 {
                throw ValidationError("Bit rate must be greater than 0.")
            }
            if let audioSampleRate, audioSampleRate <= 0 {
                throw ValidationError("Audio sample rate must be greater than 0.")
            }
            if let audioChannels, audioChannels <= 0 {
                throw ValidationError("Audio channels must be greater than 0.")
            }
            if let systemGain, systemGain <= 0 {
                throw ValidationError("System gain must be greater than 0.")
            }
        }

        let maxSizeBytes = maxSizeMB.map { Int64($0 * 1_048_576) }

        let baseSize: CGSize
        if let window = chosenWindow {
            baseSize = window.frame.size
        } else if let display = chosenDisplay {
            baseSize = CGSize(width: display.width, height: display.height)
        } else {
            baseSize = CGSize(width: 1920, height: 1080)
        }

        let regionRect = try region.map { try parseRegion($0, baseSize: baseSize) }
        let videoCodec = codec ?? .h264

        let filter: SCContentFilter
        if let window = chosenWindow {
            ensureWindowServerConnection()
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = chosenDisplay {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            throw ValidationError("No display or window selected for capture.")
        }

        let config = SCStreamConfiguration()
        let pointScale = Double(filter.pointPixelScale)
        let regionPointsSize = regionRect?.size ?? baseSize
        let regionPixelSize = CGSize(
            width: regionPointsSize.width * pointScale,
            height: regionPointsSize.height * pointScale
        )
        var targetPixelSize = scaledSize(base: regionPixelSize, scale: scale ?? 1.0)
        if !screenshot && videoCodec == .h264 {
            let maxDimension = max(targetPixelSize.width, targetPixelSize.height)
            if maxDimension > 4096 {
                let factor = 4096.0 / maxDimension
                targetPixelSize = scaledSize(base: targetPixelSize, scale: factor)
                log("H.264 max dimension is 4096; downscaling to \(Int(targetPixelSize.width))x\(Int(targetPixelSize.height)). Use --codec hevc/prores or --scale to control.")
            }
        }
        config.width = evenPixelInt(targetPixelSize.width)
        config.height = evenPixelInt(targetPixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = !hideCursor
        if showClicks {
            if #available(macOS 15.0, *) {
                config.showMouseClicks = true
            } else {
                log("Mouse click highlights require macOS 15 or later; ignoring --show-clicks.")
            }
        }
        if let fps {
            config.minimumFrameInterval = CMTimeMakeWithSeconds(1.0 / fps, preferredTimescale: 600)
        } else {
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        }
        if let regionRect {
            config.sourceRect = regionRect
        }
        if scale != nil && scale != 1.0 {
            config.scalesToFit = true
        }

        let audioMode = audio ?? .none
        let audioSampleRateValue = audioSampleRate ?? 48_000
        let audioChannelsValue = audioChannels ?? 2
        let systemGainValue = Float(systemGain ?? 1.0)
        var microphoneCaptureDeviceID: String?
        var captureSystemAudio = false
        var captureMicrophoneAudio = false
        var audioSettings: [String: Any]?
        let effectiveAudioMode: ScreenAudio

        if screenshot {
            effectiveAudioMode = .none
        } else {
            if audioMode != .none {
                if audioMode == .system || audioMode == .both {
                    config.capturesAudio = true
                    captureSystemAudio = true
                } else if systemGain != nil {
                    throw ValidationError("--system-gain is only supported with --audio system or --audio both.")
                }
                if audioMode == .mic || audioMode == .both {
                    let micGranted = await requestMicrophonePermission()
                    guard micGranted else {
                        log("""
                        Microphone permission not granted.

                        Enable it in:
                          System Settings → Privacy & Security → Microphone → (Terminal / iTerm / your terminal)
                        """)
                        throw ExitCode(2)
                    }
                    guard let micID = AVCaptureDevice.default(for: .audio)?.uniqueID else {
                        throw ValidationError("No default microphone available for capture.")
                    }
                    config.captureMicrophone = true
                    config.microphoneCaptureDeviceID = micID
                    microphoneCaptureDeviceID = micID
                    captureMicrophoneAudio = true
                }
                config.sampleRate = audioSampleRateValue
                config.channelCount = audioChannelsValue
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRateValue,
                    AVNumberOfChannelsKey: audioChannelsValue,
                    AVEncoderBitRateKey: 128_000
                ]
            }
            effectiveAudioMode = (captureSystemAudio || captureMicrophoneAudio) ? audioMode : .none
        }

        if screenshot {
            let outputURL = try resolveOutputURL(
                output: output,
                name: name,
                fileExtension: ScreenshotFormat.png.fileExtension,
                chunkIndex: nil,
                requireDirectory: false,
                prefix: "record-screenshot"
            )

            if FileManager.default.fileExists(atPath: outputURL.path) {
                if overwrite {
                    try FileManager.default.removeItem(at: outputURL)
                } else {
                    throw ValidationError("Output file already exists. Use --overwrite to replace it.")
                }
            }

            let format = try resolveScreenshotFormat(from: outputURL)
            let capturer = try ScreenShotCapturer(filter: filter, configuration: config)
            let image = try await capturer.capture()
            try writeScreenshotImage(image, to: outputURL, format: format)

            if json {
                struct Output: Codable {
                    let path: String
                    let format: String
                    let width: Int
                    let height: Int
                }
                let out = Output(
                    path: outputURL.path,
                    format: format.name,
                    width: image.width,
                    height: image.height
                )
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(outputURL.path())
            }
            return
        }

        var compression: [String: Any] = [
            kVTCompressionPropertyKey_RealTime as String: true
        ]
        if let bitRate, videoCodec != .prores {
            compression[AVVideoAverageBitRateKey] = bitRate
        }

        let stopKeyValue = stopKey ?? "s"
        let pauseKeyValue = pauseKey ?? "p"
        let resumeKeyValue = resumeKey ?? "r"
        let togglePauseResume = pauseKeyValue.caseInsensitiveCompare(resumeKeyValue) == .orderedSame
        let stopKeys = try resolveKeySet(stopKeyValue, label: "Stop key")
        let pauseKeys = try resolveKeySet(pauseKeyValue, label: "Pause key")
        let resumeKeys = try resolveKeySet(resumeKeyValue, label: "Resume key")
        let stopKeyDisplay = stopKeyValue.uppercased()
        let pauseKeyDisplay = pauseKeyValue.uppercased()
        let resumeKeyDisplay = resumeKeyValue.uppercased()

        if !stopKeys.isDisjoint(with: pauseKeys) {
            throw ValidationError("Stop key and pause key must be different.")
        }
        if !stopKeys.isDisjoint(with: resumeKeys) {
            throw ValidationError("Stop key and resume key must be different.")
        }
        if !togglePauseResume, !pauseKeys.isDisjoint(with: resumeKeys) {
            throw ValidationError("Pause key and resume key must be different unless you want a toggle.")
        }

        let shouldSplit = split != nil
        let overallDeadline = duration.map { Date().addingTimeInterval($0) }
        var chunkIndex = 1

        let stopFlag = AtomicBool()
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            stopFlag.set()
        }
        signalSource.resume()
        defer { signalSource.cancel() }

        while true {
            if let overallDeadline, overallDeadline <= Date() {
                break
            }

            let outputURL = try resolveOutputURL(
                output: output,
                name: name,
                fileExtension: (videoCodec.fileType == .mov ? "mov" : "mp4"),
                chunkIndex: shouldSplit ? chunkIndex : nil,
                requireDirectory: shouldSplit
            )

            if FileManager.default.fileExists(atPath: outputURL.path) {
                if overwrite {
                    try FileManager.default.removeItem(at: outputURL)
                } else {
                    throw ValidationError("Output file already exists. Use --overwrite to replace it.")
                }
            }

            let recorder = try ScreenRecorder(
                outputURL: outputURL,
                fileType: videoCodec.fileType,
                videoCodec: videoCodec.avType,
                filter: filter,
                configuration: config,
                compression: compression,
                audioSettings: audioSettings,
                captureSystemAudio: captureSystemAudio,
                captureMicrophoneAudio: captureMicrophoneAudio,
                microphoneCaptureDeviceID: microphoneCaptureDeviceID,
                systemGain: systemGainValue,
                audioSampleRate: audioSampleRateValue,
                audioChannels: audioChannelsValue
            )

            var stopMessage = "press '\(stopKeyDisplay)' to stop"
            if pauseKeyValue != stopKeyValue && resumeKeyValue != stopKeyValue {
                if togglePauseResume {
                    stopMessage += ", '\(pauseKeyDisplay)' to pause/resume"
                } else {
                    stopMessage += ", '\(pauseKeyDisplay)' to pause, '\(resumeKeyDisplay)' to resume"
                }
            }
            if let split {
                stopMessage += ", split every \(split)s"
            }
            if let maxSizeMB {
                stopMessage += " or when file reaches \(maxSizeMB) MB"
            }

            let chunkLabel = shouldSplit ? " (chunk \(chunkIndex))" : ""
            if let duration {
                log("Screen recording\(chunkLabel)… will stop automatically after \(duration) seconds or when you \(stopMessage).")
            } else {
                log("Screen recording\(chunkLabel)… \(stopMessage).")
            }
            if !json {
                print(outputURL.path())
            }

            try await recorder.start()

            let remainingDuration = overallDeadline.map { max(0, $0.timeIntervalSinceNow) }
            let stopReason = try await waitForStopKeyOrDuration(
                remainingDuration,
                splitDuration: split,
                stopKeys: stopKeys,
                stopKeyDisplay: stopKeyDisplay,
                pauseKeys: pauseKeys,
                resumeKeys: resumeKeys,
                pauseKeyDisplay: pauseKeyDisplay,
                resumeKeyDisplay: resumeKeyDisplay,
                togglePauseResume: togglePauseResume,
                maxSizeBytes: maxSizeBytes,
                outputURL: outputURL,
                stopFlag: stopFlag,
                recorder: recorder
            )

            try await recorder.stop()

            if json {
                struct Output: Codable {
                    let path: String
                    let codec: String
                    let fps: Double
                    let bitRate: Int?
                    let scale: Double
                    let audio: String
                    let audioSampleRate: Int?
                    let audioChannels: Int?
                    let systemGain: Double?
                    let duration: Double?
                    let maxSizeMB: Double?
                    let split: Double?
                    let chunk: Int
                    let stopReason: StopReason
                }

                let out = Output(
                    path: outputURL.path,
                    codec: videoCodec.rawValue,
                    fps: fps ?? 30,
                    bitRate: bitRate,
                    scale: scale ?? 1.0,
                    audio: effectiveAudioMode.rawValue,
                    audioSampleRate: effectiveAudioMode == .none ? nil : audioSampleRateValue,
                    audioChannels: effectiveAudioMode == .none ? nil : audioChannelsValue,
                    systemGain: (effectiveAudioMode == .system || effectiveAudioMode == .both) ? Double(systemGainValue) : nil,
                    duration: duration,
                    maxSizeMB: maxSizeMB,
                    split: split,
                    chunk: chunkIndex,
                    stopReason: stopReason
                )
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }

            if stopReason == .split {
                chunkIndex += 1
                continue
            }
            break
        }
    }

    private func normalizedTitle(_ window: SCWindow) -> String {
        (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedApp(_ window: SCWindow) -> String {
        (window.owningApplication?.applicationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchingWindows(_ windows: [SCWindow], query: String) -> [SCWindow] {
        let appExactMatches = windows.filter {
            let app = normalizedApp($0)
            return !app.isEmpty && app.caseInsensitiveCompare(query) == .orderedSame
        }
        if !appExactMatches.isEmpty {
            return appExactMatches
        }

        let titleMatches = windows.filter {
            let title = normalizedTitle($0)
            return !title.isEmpty && title.range(of: query, options: .caseInsensitive) != nil
        }
        if !titleMatches.isEmpty {
            return titleMatches
        }

        let appSubstringMatches = windows.filter {
            let app = normalizedApp($0)
            return !app.isEmpty && app.range(of: query, options: .caseInsensitive) != nil
        }
        return appSubstringMatches
    }

    private func isVisibleWindow(_ window: SCWindow) -> Bool {
        guard window.isOnScreen else { return false }
        let size = window.frame.size
        return size.width > 1 && size.height > 1
    }

    private func windowArea(_ window: SCWindow) -> Double {
        Double(window.frame.size.width * window.frame.size.height)
    }

    private func resolveWindowMatch(_ matches: [SCWindow], query: String) -> SCWindow? {
        let titleMatches = matches.filter { normalizedTitle($0).range(of: query, options: .caseInsensitive) != nil }
        if titleMatches.count == 1 {
            return titleMatches.first
        }

        let appExactMatches = matches.filter { normalizedApp($0).caseInsensitiveCompare(query) == .orderedSame }
        let baseMatches = appExactMatches.isEmpty ? matches : appExactMatches

        let visibleMatches = baseMatches.filter { isVisibleWindow($0) }
        if visibleMatches.count == 1 {
            return visibleMatches.first
        }

        let activeMatches = visibleMatches.filter { $0.isActive }
        if activeMatches.count == 1 {
            return activeMatches.first
        }

        if !visibleMatches.isEmpty {
            let maxArea = visibleMatches.map { windowArea($0) }.max() ?? 0
            let largestMatches = visibleMatches.filter { windowArea($0) == maxArea }
            if largestMatches.count == 1 {
                return largestMatches.first
            }
        }

        return nil
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = normalizedApp(window)
        let title = normalizedTitle(window)
        let appLabel = app.isEmpty ? "(unknown app)" : app
        let titleLabel = title.isEmpty ? "(untitled)" : title
        let onScreen = window.isOnScreen ? "on" : "off"
        return "\(window.windowID) \(appLabel) — \(titleLabel) [\(onScreen)]"
    }
}

private func ensureWindowServerConnection() {
    var count: UInt32 = 0
    _ = CGGetActiveDisplayList(0, nil, &count)
}

private func requestScreenRecordingPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() {
        return true
    }
    return CGRequestScreenCaptureAccess()
}

private func scaledSize(base: CGSize, scale: Double) -> CGSize {
    CGSize(width: max(1, base.width * scale), height: max(1, base.height * scale))
}

private func evenPixelInt(_ value: Double) -> Int {
    let rounded = Int(value.rounded())
    let adjusted = (rounded % 2 == 0) ? rounded : rounded + 1
    return max(2, adjusted)
}

private func parseRegion(_ spec: String, baseSize: CGSize) throws -> CGRect {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)

    func parseComponent(_ token: String, base: Double) throws -> Double {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("%") {
            let value = String(t.dropLast())
            guard let percent = Double(value) else {
                throw ValidationError("Invalid percentage value '\(token)'.")
            }
            return base * (percent / 100.0)
        }
        guard let raw = Double(t) else {
            throw ValidationError("Invalid numeric value '\(token)'.")
        }
        if raw >= 0 && raw <= 1 {
            return base * raw
        }
        return raw
    }

    if trimmed.lowercased().hasPrefix("center:") {
        let payload = trimmed.dropFirst("center:".count)
        let parts = payload.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw ValidationError("Center region must be formatted as center:WxH.")
        }
        let width = try parseComponent(String(parts[0]), base: baseSize.width)
        let height = try parseComponent(String(parts[1]), base: baseSize.height)
        guard width > 0, height > 0 else {
            throw ValidationError("Region width and height must be greater than 0.")
        }
        let x = (baseSize.width - width) / 2
        let y = (baseSize.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    let parts = trimmed.split(separator: ",").map { String($0) }
    guard parts.count == 4 else {
        throw ValidationError("Region must be formatted as x,y,w,h.")
    }
    let x = try parseComponent(parts[0], base: baseSize.width)
    let y = try parseComponent(parts[1], base: baseSize.height)
    let w = try parseComponent(parts[2], base: baseSize.width)
    let h = try parseComponent(parts[3], base: baseSize.height)
    guard w > 0, h > 0 else {
        throw ValidationError("Region width and height must be greater than 0.")
    }
    let rect = CGRect(x: x, y: y, width: w, height: h)
    guard rect.minX >= 0, rect.minY >= 0,
          rect.maxX <= baseSize.width,
          rect.maxY <= baseSize.height else {
        throw ValidationError("Region is outside bounds for the selected capture source.")
    }
    return rect
}

private final class AtomicBool {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

private func resolveKeySet(_ key: String, label: String) throws -> Set<UInt8> {
    guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII else {
        throw ValidationError("\(label) must be a single ASCII character.")
    }

    var keys: Set<UInt8> = [UInt8(scalar.value)]
    if scalar.properties.isAlphabetic {
        if let upper = key.uppercased().unicodeScalars.first {
            keys.insert(UInt8(upper.value))
        }
        if let lower = key.lowercased().unicodeScalars.first {
            keys.insert(UInt8(lower.value))
        }
    }
    return keys
}

private func formatFilename(pattern: String, date: Date, uuid: UUID, chunkIndex: Int?, prefix: String) -> String {
    var t = time_t(date.timeIntervalSince1970)
    var tm = tm()
    localtime_r(&t, &tm)

    var buffer = [CChar](repeating: 0, count: 256)
    let count = strftime(&buffer, buffer.count, pattern, &tm)
    if count == 0 {
        return "\(prefix)-\(uuid.uuidString)"
    }

    let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
    let base = String(bytes: bytes, encoding: .utf8) ?? "\(prefix)-\(uuid.uuidString)"
    var result = base.replacingOccurrences(of: "{uuid}", with: uuid.uuidString)
    if let chunkIndex {
        result = result.replacingOccurrences(of: "{chunk}", with: String(chunkIndex))
    }
    return result
}

private func resolveOutputURL(
    output: String?,
    name: String?,
    fileExtension: String,
    chunkIndex: Int?,
    requireDirectory: Bool,
    prefix: String = "record-screen"
) throws -> URL {
    let fileManager = FileManager.default
    let uuid = UUID()
    let defaultPattern = (chunkIndex == nil) ? "\(prefix)-%Y%m%d-%H%M%S" : "\(prefix)-%Y%m%d-%H%M%S-{chunk}"
    let pattern = name ?? defaultPattern

    func ensureExtension(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        if url.pathExtension.isEmpty {
            return filename + "." + fileExtension
        }
        return filename
    }

    if let output {
        let outputURL = URL(fileURLWithPath: output)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
                return outputURL.appendingPathComponent(ensureExtension(filename))
            }
            if requireDirectory {
                throw ValidationError("Output must be a directory when using --split.")
            }
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }

        if output.hasSuffix("/") {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if requireDirectory {
            if !outputURL.pathExtension.isEmpty {
                throw ValidationError("Output must be a directory when using --split.")
            }
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if outputURL.pathExtension.isEmpty {
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }
        return outputURL
    }

    let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
    let tempDir = fileManager.temporaryDirectory
    return tempDir.appendingPathComponent(ensureExtension(filename))
}

private func resolveScreenshotFormat(from url: URL) throws -> ScreenCommand.ScreenshotFormat {
    let ext = url.pathExtension.lowercased()
    let format = ext.isEmpty ? .png : ScreenCommand.ScreenshotFormat.fromExtension(ext)
    guard let resolved = format else {
        throw ValidationError("Unsupported screenshot format '.\(ext)'. Use png, jpg, jpeg, or heic.")
    }
    if resolved == .heic, !heicEncodingSupported() {
        throw ValidationError("HEIC encoding is not supported on this system.")
    }
    return resolved
}

private func heicEncodingSupported() -> Bool {
    if #available(macOS 11.0, *) {
        if let types = CGImageDestinationCopyTypeIdentifiers() as? [CFString] {
            return types.contains(UTType.heic.identifier as CFString)
        }
    }
    return false
}

private func writeScreenshotImage(
    _ image: CGImage,
    to url: URL,
    format: ScreenCommand.ScreenshotFormat
) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType, 1, nil) else {
        throw ValidationError("Unable to create image destination.")
    }

    var options: [CFString: Any] = [:]
    if format == .jpeg {
        options[kCGImageDestinationLossyCompressionQuality] = 0.9
    }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    if !CGImageDestinationFinalize(destination) {
        throw ValidationError("Unable to write screenshot.")
    }
}

private final class ScreenShotCapturer: NSObject, SCStreamOutput {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "record.screen.screenshot")
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var didCapture = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func capture() async throws -> CGImage {
        try await stream.startCapture()
        let image = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
        }
        try await stream.stopCapture()
        return image
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        lock.lock()
        if didCapture {
            lock.unlock()
            return
        }
        didCapture = true
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(returning: cgImage)
    }
}

private func waitForStopKeyOrDuration(
    _ duration: Double?,
    splitDuration: Double?,
    stopKeys: Set<UInt8>,
    stopKeyDisplay: String,
    pauseKeys: Set<UInt8>,
    resumeKeys: Set<UInt8>,
    pauseKeyDisplay: String,
    resumeKeyDisplay: String,
    togglePauseResume: Bool,
    maxSizeBytes: Int64?,
    outputURL: URL?,
    stopFlag: AtomicBool,
    recorder: ScreenRecorder?
) async throws -> StopReason {
    let rawMode = TerminalRawMode()
    defer { _ = rawMode }

    let deadline = duration.map { Date().addingTimeInterval($0) }
    var splitRemaining = splitDuration
    let sizeInterval: TimeInterval = 0.5
    var nextSizeCheck = Date()
    let fileManager = FileManager.default
    var buffer: UInt8 = 0
    var isPaused = false
    var lastTick = Date()
    var recordedDuration: TimeInterval = 0

    while true {
        if stopFlag.get() || Task.isCancelled {
            return .key
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        if !isPaused {
            recordedDuration += elapsed
        }

        if let deadline, now >= deadline {
            return .duration
        }
        if let remaining = splitRemaining, !isPaused {
            let updated = remaining - elapsed
            splitRemaining = updated
            if updated <= 0 {
                return .split
            }
        }

        if let maxSizeBytes, let outputURL, now >= nextSizeCheck {
            if let attrs = try? fileManager.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? NSNumber,
               size.int64Value >= maxSizeBytes {
                return .maxSize
            }
            nextSizeCheck = now.addingTimeInterval(sizeInterval)
        }

        var timeout = 0.25
        if let deadline {
            timeout = min(timeout, max(0, deadline.timeIntervalSince(now)))
        }
        if let splitRemaining, !isPaused {
            timeout = min(timeout, max(0, splitRemaining))
        }
        if maxSizeBytes != nil, outputURL != nil {
            timeout = min(timeout, max(0, nextSizeCheck.timeIntervalSince(now)))
        }
        let timeoutMs = Int32(max(1, Int(timeout * 1000)))

        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMs)
        if ready > 0 && (fds.revents & Int16(POLLIN)) != 0 {
            let count = read(STDIN_FILENO, &buffer, 1)
            if count == 1 {
                if stopKeys.contains(buffer) {
                    let capturedDuration = isPaused
                        ? recordedDuration
                        : (recordedDuration + Date().timeIntervalSince(lastTick))
                    log("Stop key '\(stopKeyDisplay)' received at \(formatElapsedDuration(capturedDuration)). Stopping.")
                    return .key
                }
                if togglePauseResume && pauseKeys.contains(buffer) {
                    if isPaused {
                        recorder?.setPaused(false)
                        isPaused = false
                        log("Resumed. Press '\(pauseKeyDisplay)' to pause.")
                    } else {
                        recorder?.setPaused(true)
                        isPaused = true
                        log("Paused. Press '\(pauseKeyDisplay)' to resume.")
                    }
                } else if pauseKeys.contains(buffer), !isPaused {
                    recorder?.setPaused(true)
                    isPaused = true
                    log("Paused. Press '\(resumeKeyDisplay)' to resume.")
                } else if resumeKeys.contains(buffer), isPaused {
                    recorder?.setPaused(false)
                    isPaused = false
                    log("Resumed.")
                }
            }
        }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let videoQueue = DispatchQueue(label: "record.screen.capture.video")
    private let audioQueue = DispatchQueue(label: "record.screen.capture.audio")
    private let stateLock = NSLock()
    private let writerLock = NSLock()
    private var paused = false
    private var pauseStartTime: CMTime?
    private var pauseOffset = CMTime.zero
    private let outputURL: URL
    private let fileType: AVFileType
    private let videoCodec: AVVideoCodecType
    private let compression: [String: Any]
    private let audioSettings: [String: Any]?
    private let captureSystemAudio: Bool
    private let captureMicrophoneAudio: Bool
    private let audioPipeline: StreamAudioPipeline?
    private var sessionStartTime: CMTime?
    private var receivedSystemAudio = false
    private var receivedMicrophoneAudio = false
    private var loggedWriterFailure = false
    private var isStopping = false
    private var lastVideoPTS: CMTime?
    private var loggedNonMonotonicVideoPTS = false

    init(
        outputURL: URL,
        fileType: AVFileType,
        videoCodec: AVVideoCodecType,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        compression: [String: Any],
        audioSettings: [String: Any]?,
        captureSystemAudio: Bool,
        captureMicrophoneAudio: Bool,
        microphoneCaptureDeviceID: String?,
        systemGain: Float,
        audioSampleRate: Int,
        audioChannels: Int
    ) throws {
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.outputURL = outputURL
        self.fileType = fileType
        self.videoCodec = videoCodec
        self.compression = compression
        self.audioSettings = audioSettings
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophoneAudio = captureMicrophoneAudio
        if captureMicrophoneAudio,
           let microphoneCaptureDeviceID {
            configuration.microphoneCaptureDeviceID = microphoneCaptureDeviceID
        }
        if captureSystemAudio || captureMicrophoneAudio {
            let mixMode: StreamAudioMixMode
            if captureSystemAudio && captureMicrophoneAudio {
                mixMode = .both
            } else if captureSystemAudio {
                mixMode = .system
            } else {
                mixMode = .microphone
            }
            self.audioPipeline = try StreamAudioPipeline(
                mode: mixMode,
                sampleRate: audioSampleRate,
                channels: audioChannels,
                systemGain: systemGain
            )
        } else {
            self.audioPipeline = nil
        }

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if captureMicrophoneAudio {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws {
        writerLock.withLock {
            isStopping = true
        }
        try await stream.stopCapture()
        // SCStream may still have in-flight callbacks queued; drain them before
        // marking writer inputs finished.
        videoQueue.sync {}
        audioQueue.sync {}
        if captureMicrophoneAudio && !receivedMicrophoneAudio {
            log("Warning: no microphone samples were received during screen capture.")
        }
        if captureSystemAudio && !receivedSystemAudio {
            log("Warning: no system audio samples were received during screen capture.")
        }
        let tuple = writerLock.withLock {
            let tuple = (self.writer, self.input, self.audioInput)
            tuple.1?.markAsFinished()
            tuple.2?.markAsFinished()
            return tuple
        }
        guard tuple.0 != nil else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.writer?.finishWriting { [self] in
                let error = writerLock.withLock { self.writer?.error }
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen || type == .audio || type == .microphone else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pauseState = pauseSnapshot()
        if pauseState.paused { return }

        var adjustedBuffer = sampleBuffer
        if pauseState.offset.isValid, CMTimeCompare(pauseState.offset, .zero) == 1 {
            if let shifted = adjustSampleBuffer(sampleBuffer, by: pauseState.offset) {
                adjustedBuffer = shifted
            }
        }

        if type == .screen {
            if !isCompleteScreenFrame(adjustedBuffer) {
                return
            }
            writerLock.lock()
            defer { writerLock.unlock() }
            if isStopping {
                return
            }
            if !ensureWriterLocked(sampleBuffer: adjustedBuffer) {
                return
            }
            guard let writer, let input else { return }
            if writer.status == .failed {
                if !loggedWriterFailure {
                    loggedWriterFailure = true
                    log("Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
                }
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)
            if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) <= 0 {
                if !loggedNonMonotonicVideoPTS {
                    loggedNonMonotonicVideoPTS = true
                    log("Skipping non-monotonic video frame timestamp while recording.")
                }
                return
            }
            if input.isReadyForMoreMediaData, !input.append(adjustedBuffer) {
                if !loggedWriterFailure {
                    loggedWriterFailure = true
                    log("Failed to append video buffer: \(writer.error?.localizedDescription ?? "unknown error")")
                }
            } else if input.isReadyForMoreMediaData {
                lastVideoPTS = pts
            }
            return
        }

        guard let audioPipeline else {
            return
        }

        let source: StreamAudioSourceKind = (type == .audio) ? .system : .microphone
        if source == .system {
            receivedSystemAudio = true
        } else {
            receivedMicrophoneAudio = true
        }
        let mixedBuffers = audioPipeline.append(sampleBuffer: adjustedBuffer, source: source)

        writerLock.lock()
        defer { writerLock.unlock() }
        if isStopping {
            return
        }
        guard let writer, let audioInput else {
            return
        }
        guard writer.status != .unknown else {
            return
        }
        if writer.status == .failed {
            if !loggedWriterFailure {
                loggedWriterFailure = true
                log("Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
            }
            return
        }

        for mixedBuffer in mixedBuffers {
            let pts = CMSampleBufferGetPresentationTimeStamp(mixedBuffer)
            if let sessionStartTime, CMTimeCompare(pts, sessionStartTime) < 0 {
                continue
            }
            if audioInput.isReadyForMoreMediaData, !audioInput.append(mixedBuffer) {
                if !loggedWriterFailure {
                    loggedWriterFailure = true
                    log("Failed to append audio buffer: \(writer.error?.localizedDescription ?? "unknown error")")
                }
                return
            }
        }
    }

    func setPaused(_ paused: Bool) {
        stateLock.lock()
        if paused {
            if !self.paused {
                self.paused = true
                pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
            }
        } else {
            if self.paused {
                self.paused = false
                if let pauseStartTime {
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    let delta = CMTimeSubtract(now, pauseStartTime)
                    if delta.isValid, CMTimeCompare(delta, .zero) == 1 {
                        pauseOffset = CMTimeAdd(pauseOffset, delta)
                    }
                }
                pauseStartTime = nil
            }
        }
        stateLock.unlock()
    }

    private func pauseSnapshot() -> (paused: Bool, offset: CMTime) {
        stateLock.lock()
        let value = paused
        let offset = pauseOffset
        stateLock.unlock()
        return (value, offset)
    }

    private func ensureWriterLocked(sampleBuffer: CMSampleBuffer) -> Bool {
        if writer != nil {
            return true
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return false
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        var outputSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if !compression.isEmpty {
            outputSettings[AVVideoCompressionPropertiesKey] = compression
        }

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
            } else {
                log("Unable to configure video writer input.")
                return false
            }

            var audioInput: AVAssetWriterInput?
            if (captureSystemAudio || captureMicrophoneAudio), let audioSettings {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audio.expectsMediaDataInRealTime = true
                if writer.canAdd(audio) {
                    writer.add(audio)
                    audioInput = audio
                } else {
                    log("Unable to add audio writer input; continuing without audio.")
                }
            }

            self.writer = writer
            self.input = input
            self.audioInput = audioInput

            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
            self.sessionStartTime = startTime
        } catch {
            log("Failed to initialize writer: \(error)")
            return false
        }

        return true
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first,
        let statusRawValue = attachments[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return true
        }
        return status == .complete
    }

    private func adjustSampleBuffer(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var timingCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard status == noErr, timingCount > 0 else {
            return sampleBuffer
        }

        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: timingCount
        )
        status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingCount,
            arrayToFill: &timing,
            entriesNeededOut: &timingCount
        )
        guard status == noErr else {
            return sampleBuffer
        }

        for index in 0..<timingCount {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            }
        }

        var adjusted: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        )
        guard status == noErr else {
            return sampleBuffer
        }
        return adjusted
    }
}
