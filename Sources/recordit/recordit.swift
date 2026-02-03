@preconcurrency import AVFoundation
import ArgumentParser
import Foundation
import Darwin

// Keep stdout clean for piping: put status/errors on stderr
func log(_ message: String) {
    let data = (message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
}

enum StopReason: String, Codable {
    case key
    case duration
}

// Read single key without requiring Enter
final class TerminalRawMode {
    private var original = termios()
    private var active = false

    init() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        tcgetattr(STDIN_FILENO, &original)

        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.6 /* VMIN */ = 1
        raw.c_cc.5 /* VTIME */ = 0

        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        active = true
    }

    deinit {
        guard active else { return }
        var orig = original
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
    }
}

func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

// AVFoundation types are not Sendable; keep them on MainActor.
@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    let outputURL: URL
    let settings: [String: Any]

    init(outputURL: URL, settings: [String: Any]) {
        self.outputURL = outputURL
        self.settings = settings
    }

    func start() throws {
        let r = try AVAudioRecorder(url: outputURL, settings: settings)
        r.prepareToRecord()

        guard r.record() else {
            throw NSError(domain: "micrec", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        }
        recorder = r
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

func waitForStopKeyOrDuration(_ duration: Double?) async throws -> StopReason {
    let rawMode = TerminalRawMode()
    let deadline = duration.map { Date().addingTimeInterval($0) }

    return withExtendedLifetime(rawMode) {
        var buffer: UInt8 = 0

        while true {
            if Task.isCancelled {
                return .key
            }

            if let deadline, deadline.timeIntervalSinceNow <= 0 {
                return .duration
            }

            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let timeoutMs: Int32
            if let deadline {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                let slice = min(remaining, 0.25)
                timeoutMs = Int32(max(1, Int(slice * 1000)))
            } else {
                timeoutMs = 250
            }

            let ready = poll(&fds, 1, timeoutMs)
            if ready > 0 && (fds.revents & Int16(POLLIN)) != 0 {
                let count = read(STDIN_FILENO, &buffer, 1)
                if count == 1 {
                    if buffer == UInt8(ascii: "s") || buffer == UInt8(ascii: "S") {
                        return .key
                    }
                }
            }
        }
    }
}

@main
struct MicRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio from the default microphone to a temporary file.",
        discussion: """
        The output file path is printed to stdout (pipeline-friendly). Status messages \
        go to stderr.
        """
    )

    enum AudioFormat: String, CaseIterable, ExpressibleByArgument {
        case aac
        case alac
        case linearPCM
        case appleIMA4
        case ulaw
        case alaw

        var formatID: UInt32 {
            switch self {
            case .aac: return kAudioFormatMPEG4AAC
            case .alac: return kAudioFormatAppleLossless
            case .linearPCM: return kAudioFormatLinearPCM
            case .appleIMA4: return kAudioFormatAppleIMA4
            case .ulaw: return kAudioFormatULaw
            case .alaw: return kAudioFormatALaw
            }
        }

        var fileExtension: String {
            switch self {
            case .aac, .alac:
                return "m4a"
            case .linearPCM, .appleIMA4, .ulaw, .alaw:
                return "caf"
            }
        }
    }

    enum AudioQuality: String, CaseIterable, ExpressibleByArgument {
        case min
        case low
        case medium
        case high
        case max

        var avValue: Int {
            switch self {
            case .min: return AVAudioQuality.min.rawValue
            case .low: return AVAudioQuality.low.rawValue
            case .medium: return AVAudioQuality.medium.rawValue
            case .high: return AVAudioQuality.high.rawValue
            case .max: return AVAudioQuality.max.rawValue
            }
        }
    }

    @Option(help: "Stop recording after this many seconds. If omitted, press 'S' to stop.")
    var duration: Double?

    @Option(help: "Write output to this file or directory. Default: temporary directory.")
    var output: String?

    @Option(help: "Filename pattern when output is a directory. Supports strftime tokens and {uuid}. Default: micrec-%Y%m%d-%H%M%S.")
    var name: String?

    @Flag(help: "Overwrite output file if it exists.")
    var overwrite = false

    @Flag(help: "Print machine-readable JSON to stdout.")
    var json = false

    @Option(help: "Sample rate in Hz. Default: 44100.")
    var sampleRate: Double?

    @Option(help: "Number of channels. Default: 1.")
    var channels: Int?

    @Option(help: "Encoder bit rate in bps. Default: 128000. Ignored for linearPCM.")
    var bitRate: Int?

    @Option(help: "Audio format. Default: linearPCM.")
    var format: AudioFormat?

    @Option(help: "Encoder quality. Default: high.")
    var quality: AudioQuality?

    mutating func validate() throws {
        if let duration, duration <= 0 {
            throw ValidationError("Duration must be greater than 0 seconds.")
        }
        if let sampleRate, sampleRate <= 0 {
            throw ValidationError("Sample rate must be greater than 0.")
        }
        if let channels, channels <= 0 {
            throw ValidationError("Number of channels must be greater than 0.")
        }
        if let bitRate, bitRate <= 0 {
            throw ValidationError("Bit rate must be greater than 0.")
        }
    }

    func buildSettings() -> [String: Any] {
        let resolvedFormat = format ?? .linearPCM
        var settings: [String: Any] = [
            AVFormatIDKey: resolvedFormat.formatID,
            AVSampleRateKey: sampleRate ?? 44_100,
            AVNumberOfChannelsKey: channels ?? 1,
            AVEncoderAudioQualityKey: (quality ?? .high).avValue
        ]

        if resolvedFormat != .linearPCM {
            if let bitRate {
                settings[AVEncoderBitRateKey] = bitRate
            } else {
                settings[AVEncoderBitRateKey] = 128_000
            }
        }

        if resolvedFormat == .linearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        }

        return settings
    }

    func formatFilename(pattern: String, date: Date, uuid: UUID) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tm = tm()
        localtime_r(&t, &tm)

        var buffer = [CChar](repeating: 0, count: 256)
        let count = strftime(&buffer, buffer.count, pattern, &tm)
        if count == 0 {
            return "micrec-\(uuid.uuidString)"
        }

        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        let base = String(bytes: bytes, encoding: .utf8) ?? "micrec-\(uuid.uuidString)"
        return base.replacingOccurrences(of: "{uuid}", with: uuid.uuidString)
    }

    func resolveOutputURL(extension fileExtension: String) throws -> URL {
        let fileManager = FileManager.default
        let uuid = UUID()
        let pattern = name ?? "micrec-%Y%m%d-%H%M%S"

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
                    let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid)
                    return outputURL.appendingPathComponent(ensureExtension(filename))
                }
                return URL(fileURLWithPath: ensureExtension(outputURL.path))
            }

            if output.hasSuffix("/") {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid)
                return outputURL.appendingPathComponent(ensureExtension(filename))
            }

            if outputURL.pathExtension.isEmpty {
                return URL(fileURLWithPath: ensureExtension(outputURL.path))
            }
            return outputURL
        }

        let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid)
        let tempDir = fileManager.temporaryDirectory
        return tempDir.appendingPathComponent(ensureExtension(filename))
    }

    mutating func run() async throws {
        do {
            let granted = await requestMicrophonePermission()
            guard granted else {
                log("""
                Microphone permission not granted.

                Since this is a CLI tool, macOS usually assigns microphone permission to your terminal app.
                Enable it in:
                  System Settings → Privacy & Security → Microphone → (Terminal / iTerm / your terminal)
                """)
                throw ExitCode(2)
            }

            let settings = buildSettings()
            let extensionOverride = (format ?? .linearPCM).fileExtension
            let url = try resolveOutputURL(extension: extensionOverride)

            if !overwrite && FileManager.default.fileExists(atPath: url.path) {
                throw ValidationError("Output file already exists. Use --overwrite to replace it.")
            }

            let recorder = await MainActor.run { AudioRecorder(outputURL: url, settings: settings) }
            try await MainActor.run { try recorder.start() }

            if let duration {
                log("Recording… will stop automatically after \(duration) seconds or when you press 'S'.")
            } else {
                log("Recording… press 'S' to stop.")
            }

            let stopReason = try await waitForStopKeyOrDuration(duration)

            await MainActor.run { recorder.stop() }

            // stdout: print ONLY the URL (pipeline-friendly)
            if json {
                struct Output: Codable {
                    let path: String
                    let format: String
                    let sampleRate: Double
                    let channels: Int
                    let bitRate: Int?
                    let quality: String
                    let duration: Double?
                    let stopReason: StopReason
                }

                let resolvedFormat = (format ?? .linearPCM)
                let out = Output(
                    path: url.path,
                    format: resolvedFormat.rawValue,
                    sampleRate: sampleRate ?? 44_100,
                    channels: channels ?? 1,
                    bitRate: resolvedFormat == .linearPCM ? nil : (bitRate ?? 128_000),
                    quality: (quality ?? .high).rawValue,
                    duration: duration,
                    stopReason: stopReason
                )
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(url.path())
            }
        } catch {
            log("Error: \(error)")
            throw ExitCode(1)
        }
    }
}
