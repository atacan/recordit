import ArgumentParser
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
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

    mutating func run() async throws {
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
            if let windowID = UInt32(window) {
                chosenWindow = content.windows.first { $0.windowID == windowID }
            } else {
                let matches = content.windows.filter {
                    let title = $0.title ?? ""
                    let app = $0.owningApplication?.applicationName ?? ""
                    return title.range(of: window, options: .caseInsensitive) != nil ||
                        app.range(of: window, options: .caseInsensitive) != nil
                }
                if matches.count == 1 {
                    chosenWindow = matches.first
                } else if matches.isEmpty {
                    throw ValidationError("No window matches '\(window)'. Use --list-windows to see available windows.")
                } else {
                    let names = matches.compactMap { $0.title ?? $0.owningApplication?.applicationName }.joined(separator: ", ")
                    throw ValidationError("Multiple windows match '\(window)': \(names). Please be more specific.")
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
        let targetSize = scaledSize(base: regionRect?.size ?? baseSize, scale: scale ?? 1.0)
        let videoCodec = codec ?? .h264

        let filter: SCContentFilter
        if let window = chosenWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = chosenDisplay {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            throw ValidationError("No display or window selected for capture.")
        }

        let config = SCStreamConfiguration()
        config.width = Int(targetSize.width.rounded())
        config.height = Int(targetSize.height.rounded())
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
        var captureAudio = false
        var audioSettings: [String: Any]?

        if audioMode != .none {
            if audioMode == .system || audioMode == .both {
                config.capturesAudio = true
                captureAudio = true
            }
            if audioMode == .mic || audioMode == .both {
                if #available(macOS 15.0, *) {
                    config.captureMicrophone = true
                    captureAudio = true
                } else {
                    log("Microphone capture requires macOS 15 or later; ignoring mic audio.")
                }
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
        let effectiveAudioMode: ScreenAudio = captureAudio ? audioMode : .none

        var compression: [String: Any] = [:]
        if let bitRate, videoCodec != .prores {
            compression[AVVideoAverageBitRateKey] = bitRate
        }
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec.avType,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ]
        if !compression.isEmpty {
            outputSettings[AVVideoCompressionPropertiesKey] = compression
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
                filter: filter,
                configuration: config,
                outputSettings: outputSettings,
                audioSettings: audioSettings,
                captureAudio: captureAudio
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
}

private func scaledSize(base: CGSize, scale: Double) -> CGSize {
    CGSize(width: max(1, base.width * scale), height: max(1, base.height * scale))
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

private func formatFilename(pattern: String, date: Date, uuid: UUID, chunkIndex: Int?) -> String {
    var t = time_t(date.timeIntervalSince1970)
    var tm = tm()
    localtime_r(&t, &tm)

    var buffer = [CChar](repeating: 0, count: 256)
    let count = strftime(&buffer, buffer.count, pattern, &tm)
    if count == 0 {
        return "recordit-screen-\(uuid.uuidString)"
    }

    let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
    let base = String(bytes: bytes, encoding: .utf8) ?? "recordit-screen-\(uuid.uuidString)"
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
    requireDirectory: Bool
) throws -> URL {
    let fileManager = FileManager.default
    let uuid = UUID()
    let defaultPattern = (chunkIndex == nil) ? "recordit-screen-%Y%m%d-%H%M%S" : "recordit-screen-%Y%m%d-%H%M%S-{chunk}"
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
                let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex)
                return outputURL.appendingPathComponent(ensureExtension(filename))
            }
            if requireDirectory {
                throw ValidationError("Output must be a directory when using --split.")
            }
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }

        if output.hasSuffix("/") {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if requireDirectory {
            if !outputURL.pathExtension.isEmpty {
                throw ValidationError("Output must be a directory when using --split.")
            }
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if outputURL.pathExtension.isEmpty {
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }
        return outputURL
    }

    let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex)
    let tempDir = fileManager.temporaryDirectory
    return tempDir.appendingPathComponent(ensureExtension(filename))
}

private func waitForStopKeyOrDuration(
    _ duration: Double?,
    splitDuration: Double?,
    stopKeys: Set<UInt8>,
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

    while true {
        if stopFlag.get() || Task.isCancelled {
            return .key
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now

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
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "recordit.screen.capture")
    private let stateLock = NSLock()
    private var paused = false

    init(
        outputURL: URL,
        fileType: AVFileType,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputSettings: [String: Any],
        audioSettings: [String: Any]?,
        captureAudio: Bool
    ) throws {
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw NSError(domain: "recordit.screen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to configure video writer input."
            ])
        }

        if captureAudio, let audioSettings {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            } else {
                self.audioInput = nil
                log("Unable to add audio writer input; continuing without audio.")
            }
        } else {
            audioInput = nil
        }

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws {
        try await stream.stopCapture()
        input.markAsFinished()
        audioInput?.markAsFinished()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen || type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if isPaused() { return }

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }

        if writer.status == .failed {
            log("Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
            return
        }

        if type == .screen {
            if input.isReadyForMoreMediaData {
                if !input.append(sampleBuffer) {
                    log("Failed to append video buffer: \(writer.error?.localizedDescription ?? "unknown error")")
                }
            }
        } else if type == .audio, let audioInput {
            if audioInput.isReadyForMoreMediaData {
                if !audioInput.append(sampleBuffer) {
                    log("Failed to append audio buffer: \(writer.error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        stateLock.lock()
        self.paused = paused
        stateLock.unlock()
    }

    private func isPaused() -> Bool {
        stateLock.lock()
        let value = paused
        stateLock.unlock()
        return value
    }
}
