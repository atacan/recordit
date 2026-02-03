@preconcurrency import AVFoundation
import ArgumentParser
import Foundation
import Darwin

// Keep stdout clean for piping: put status/errors on stderr
func log(_ message: String) {
    let data = (message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
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

func waitForStopKeyOrDuration(_ duration: Double?) async throws {
    let rawMode = TerminalRawMode()
    let deadline = duration.map { Date().addingTimeInterval($0) }

    withExtendedLifetime(rawMode) {
        var buffer: UInt8 = 0

        while true {
            if Task.isCancelled {
                return
            }

            if let deadline, deadline.timeIntervalSinceNow <= 0 {
                return
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
                        return
                    }
                }
            }
        }
    }
}

@main
struct MicRec: AsyncParsableCommand {
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

    @Option(help: "Stop recording after this many seconds.")
    var duration: Double?

    @Option(help: "Sample rate in Hz.")
    var sampleRate: Double?

    @Option(help: "Number of channels.")
    var channels: Int?

    @Option(help: "Encoder bit rate in bps.")
    var bitRate: Int?

    @Option(help: "Audio format.")
    var format: AudioFormat?

    @Option(help: "Encoder quality.")
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
        let resolvedFormat = format ?? .aac
        var settings: [String: Any] = [
            AVFormatIDKey: resolvedFormat.formatID,
            AVSampleRateKey: sampleRate ?? 44_100,
            AVNumberOfChannelsKey: channels ?? 1,
            AVEncoderAudioQualityKey: (quality ?? .high).avValue
        ]

        if let bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        } else {
            settings[AVEncoderBitRateKey] = 128_000
        }

        if resolvedFormat == .linearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        }

        return settings
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
            let extensionOverride = (format ?? .aac).fileExtension
            let filename = "micrec-\(UUID().uuidString).\(extensionOverride)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let recorder = await MainActor.run { AudioRecorder(outputURL: url, settings: settings) }
            try await MainActor.run { try recorder.start() }

            if let duration {
                log("Recording… will stop automatically after \(duration) seconds or when you press 'S'.")
            } else {
                log("Recording… press 'S' to stop.")
            }

            try await waitForStopKeyOrDuration(duration)

            await MainActor.run { recorder.stop() }

            // stdout: print ONLY the URL (pipeline-friendly)
            print(url.path())
        } catch {
            log("Error: \(error)")
            throw ExitCode(1)
        }
    }
}
