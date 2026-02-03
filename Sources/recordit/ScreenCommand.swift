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

    @Option(help: "Stop recording after this many seconds. If omitted, press Ctrl-C to stop.")
    var duration: Double?

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

        let baseSize: CGSize
        if let window = chosenWindow {
            baseSize = window.frame.size
        } else if let display = chosenDisplay {
            baseSize = CGSize(width: display.width, height: display.height)
        } else {
            baseSize = CGSize(width: 1920, height: 1080)
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

        let regionRect = try region.map { try parseRegion($0, baseSize: baseSize) }
        let targetSize = scaledSize(base: regionRect?.size ?? baseSize, scale: scale ?? 1.0)
        let videoCodec = codec ?? .h264

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recordit-screen-\(UUID().uuidString).\(videoCodec.fileType == .mov ? "mov" : "mp4")"
        )

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

        let recorder = try ScreenRecorder(
            outputURL: outputURL,
            fileType: videoCodec.fileType,
            filter: filter,
            configuration: config,
            outputSettings: outputSettings
        )

        let signalStream = AsyncStream<Void> { continuation in
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            source.resume()
            continuation.onTermination = { _ in
                source.cancel()
            }
        }

        if let duration {
            log("Screen recording… will stop automatically after \(duration) seconds (or Ctrl-C to stop).")
        } else {
            log("Screen recording… press Ctrl-C to stop.")
        }
        print(outputURL.path())

        try await recorder.start()

        if let duration {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            for await _ in signalStream {
                break
            }
        }

        try await recorder.stop()
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

final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "recordit.screen.capture")

    init(
        outputURL: URL,
        fileType: AVFileType,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputSettings: [String: Any]
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

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws {
        try await stream.stopCapture()
        input.markAsFinished()
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
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }

        if writer.status == .failed {
            log("Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
            return
        }

        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                log("Failed to append sample buffer: \(writer.error?.localizedDescription ?? "unknown error")")
            }
        }
    }
}
