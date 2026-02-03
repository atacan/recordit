@preconcurrency import AVFoundation
import ArgumentParser
import CoreAudio
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
    case silence
}

struct AudioInputDevice: Codable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct SilenceConfig {
    let db: Double
    let duration: Double
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

func defaultInputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceID = AudioDeviceID(0)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceID
    )
    guard status == noErr else {
        throw ValidationError("Unable to read default input device (CoreAudio error \(status)).")
    }
    return deviceID
}

func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = deviceID
    let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        dataSize,
        &deviceID
    )
    guard status == noErr else {
        throw ValidationError("Unable to set default input device (CoreAudio error \(status)).")
    }
}

func listInputDevices() throws -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize
    )
    guard status == noErr else {
        throw ValidationError("Unable to list audio devices (CoreAudio error \(status)).")
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceIDs
    )
    guard status == noErr else {
        throw ValidationError("Unable to list audio devices (CoreAudio error \(status)).")
    }

    func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(deviceID), &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, buffer)
        guard status == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        let channels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    func readStringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &dataSize, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    var devices: [AudioInputDevice] = []
    for id in deviceIDs where hasInputChannels(id) {
        guard let uid = readStringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
              let name = readStringProperty(kAudioObjectPropertyName, deviceID: id) else {
            continue
        }
        devices.append(AudioInputDevice(id: id, uid: uid, name: name))
    }

    return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    func pause() {
        recorder?.pause()
    }

    func resume() {
        _ = recorder?.record()
    }

    func setMeteringEnabled(_ enabled: Bool) {
        recorder?.isMeteringEnabled = enabled
    }

    func averagePower() -> Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160.0
    }
}

func waitForStopKeyOrDuration(
    _ duration: Double?,
    stopKeys: Set<UInt8>,
    pauseKeys: Set<UInt8>,
    resumeKeys: Set<UInt8>,
    pauseKeyDisplay: String,
    resumeKeyDisplay: String,
    togglePauseResume: Bool,
    silence: SilenceConfig?,
    recorder: AudioRecorder?
) async throws -> StopReason {
    let rawMode = TerminalRawMode()
    defer { _ = rawMode }

    let deadline = duration.map { Date().addingTimeInterval($0) }
    let meterInterval: TimeInterval = 0.2
    var nextMeterCheck = Date()
    var silenceStart: Date?
    var buffer: UInt8 = 0
    var isPaused = false

    while true {
        if Task.isCancelled {
            return .key
        }

        let now = Date()
        if let deadline, now >= deadline {
            return .duration
        }

        if let silence, let recorder, !isPaused, now >= nextMeterCheck {
            let power = await MainActor.run { recorder.averagePower() }
            if Double(power) <= silence.db {
                silenceStart = silenceStart ?? now
                if let silenceStart, now.timeIntervalSince(silenceStart) >= silence.duration {
                    return .silence
                }
            } else {
                silenceStart = nil
            }
            nextMeterCheck = now.addingTimeInterval(meterInterval)
        } else if isPaused {
            silenceStart = nil
            nextMeterCheck = now.addingTimeInterval(meterInterval)
        }

        var timeout = 0.25
        if let deadline {
            timeout = min(timeout, max(0, deadline.timeIntervalSince(now)))
        }
        if silence != nil, recorder != nil {
            timeout = min(timeout, max(0, nextMeterCheck.timeIntervalSince(now)))
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
                        if let recorder {
                            await MainActor.run { recorder.resume() }
                        }
                        isPaused = false
                        log("Resumed. Press '\(pauseKeyDisplay)' to pause.")
                    } else {
                        if let recorder {
                            await MainActor.run { recorder.pause() }
                        }
                        isPaused = true
                        log("Paused. Press '\(pauseKeyDisplay)' to resume.")
                    }
                } else if pauseKeys.contains(buffer), !isPaused {
                    if let recorder {
                        await MainActor.run { recorder.pause() }
                    }
                    isPaused = true
                    log("Paused. Press '\(resumeKeyDisplay)' to resume.")
                } else if resumeKeys.contains(buffer), isPaused {
                    if let recorder {
                        await MainActor.run { recorder.resume() }
                    }
                    isPaused = false
                    log("Resumed.")
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

    @Flag(help: "List available input devices and exit.")
    var listDevices = false

    @Flag(help: "List available audio formats and exit.")
    var listFormats = false

    @Flag(help: "List available encoder qualities and exit.")
    var listQualities = false

    @Option(help: "Input device UID or name to use for recording.")
    var device: String?

    @Option(help: "Stop key (single ASCII character). Default: s.")
    var stopKey: String?

    @Option(help: "Pause key (single ASCII character). Default: p. If same as resume key, toggles pause/resume.")
    var pauseKey: String?

    @Option(help: "Resume key (single ASCII character). Default: r. If same as pause key, toggles pause/resume.")
    var resumeKey: String?

    @Option(help: "Silence threshold in dBFS (e.g. -50). Requires --silence-duration.")
    var silenceDB: Double?

    @Option(help: "Stop after this many seconds of continuous silence. Requires --silence-db.")
    var silenceDuration: Double?

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
        let stopKeyValue = stopKey ?? "s"
        let pauseKeyValue = pauseKey ?? "p"
        let resumeKeyValue = resumeKey ?? "r"
        let stopSet = try resolveKeySet(stopKeyValue, label: "Stop key")
        let pauseSet = try resolveKeySet(pauseKeyValue, label: "Pause key")
        let resumeSet = try resolveKeySet(resumeKeyValue, label: "Resume key")

        if !stopSet.isDisjoint(with: pauseSet) {
            throw ValidationError("Stop key and pause key must be different.")
        }
        if !stopSet.isDisjoint(with: resumeSet) {
            throw ValidationError("Stop key and resume key must be different.")
        }
        let pauseEqualsResume = pauseKeyValue.caseInsensitiveCompare(resumeKeyValue) == .orderedSame
        if !pauseEqualsResume, !pauseSet.isDisjoint(with: resumeSet) {
            throw ValidationError("Pause key and resume key must be different unless you want a toggle.")
        }
        if (silenceDB == nil) != (silenceDuration == nil) {
            throw ValidationError("Both --silence-db and --silence-duration must be provided together.")
        }
        if let silenceDuration, silenceDuration <= 0 {
            throw ValidationError("Silence duration must be greater than 0 seconds.")
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

    func resolveKeySet(_ key: String, label: String) throws -> Set<UInt8> {
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

    mutating func run() async throws {
        do {
            if listFormats {
                let formats = AudioFormat.allCases
                if json {
                    struct FormatOutput: Codable {
                        let format: String
                        let fileExtension: String
                    }
                    let out = formats.map { FormatOutput(format: $0.rawValue, fileExtension: $0.fileExtension) }
                    let data = try JSONEncoder().encode(out)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    for format in formats {
                        print("\(format.rawValue)\t.\(format.fileExtension)")
                    }
                }
                return
            }

            if listQualities {
                let qualities = AudioQuality.allCases.map(\.rawValue)
                if json {
                    let data = try JSONEncoder().encode(qualities)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    for quality in qualities {
                        print(quality)
                    }
                }
                return
            }

            if listDevices {
                let devices = try listInputDevices()
                let defaultID = try? defaultInputDeviceID()
                if json {
                    struct DeviceOutput: Codable {
                        let id: UInt32
                        let uid: String
                        let name: String
                        let isDefault: Bool
                    }
                    let out = devices.map {
                        DeviceOutput(
                            id: $0.id,
                            uid: $0.uid,
                            name: $0.name,
                            isDefault: $0.id == defaultID
                        )
                    }
                    let data = try JSONEncoder().encode(out)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    for device in devices {
                        let marker = (device.id == defaultID) ? "*" : " "
                        print("\(marker) \(device.name)\t\(device.uid)")
                    }
                }
                return
            }

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

            var restoreDeviceID: AudioDeviceID?
            if let device {
                let devices = try listInputDevices()
                let matches = devices.filter {
                    $0.uid.caseInsensitiveCompare(device) == .orderedSame ||
                    $0.name.range(of: device, options: .caseInsensitive) != nil
                }
                if matches.count == 1, let match = matches.first {
                    restoreDeviceID = try defaultInputDeviceID()
                    try setDefaultInputDeviceID(match.id)
                } else if matches.isEmpty {
                    throw ValidationError("No input device matches '\(device)'. Use --list-devices to see available devices.")
                } else {
                    let names = matches.map { $0.name }.joined(separator: ", ")
                    throw ValidationError("Multiple devices match '\(device)': \(names). Please be more specific.")
                }
            }

            defer {
                if let restoreDeviceID {
                    try? setDefaultInputDeviceID(restoreDeviceID)
                }
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
            let silenceConfig: SilenceConfig?
            if let silenceDB, let silenceDuration {
                silenceConfig = SilenceConfig(db: silenceDB, duration: silenceDuration)
            } else {
                silenceConfig = nil
            }

            let settings = buildSettings()
            let extensionOverride = (format ?? .linearPCM).fileExtension
            let url = try resolveOutputURL(extension: extensionOverride)

            if !overwrite && FileManager.default.fileExists(atPath: url.path) {
                throw ValidationError("Output file already exists. Use --overwrite to replace it.")
            }

            let recorder = await MainActor.run { AudioRecorder(outputURL: url, settings: settings) }
            try await MainActor.run { try recorder.start() }
            if silenceConfig != nil {
                await MainActor.run { recorder.setMeteringEnabled(true) }
            }

            var stopMessage = "press '\(stopKeyDisplay)' to stop"
            if pauseKeyValue != stopKeyValue && resumeKeyValue != stopKeyValue {
                if togglePauseResume {
                    stopMessage += ", '\(pauseKeyDisplay)' to pause/resume"
                } else {
                    stopMessage += ", '\(pauseKeyDisplay)' to pause, '\(resumeKeyDisplay)' to resume"
                }
            }
            if let silenceConfig {
                stopMessage += " or after \(silenceConfig.duration)s of silence (\(silenceConfig.db)dB)"
            }
            if let duration {
                log("Recording… will stop automatically after \(duration) seconds or when you \(stopMessage).")
            } else {
                log("Recording… \(stopMessage).")
            }

            let stopReason = try await waitForStopKeyOrDuration(
                duration,
                stopKeys: stopKeys,
                pauseKeys: pauseKeys,
                resumeKeys: resumeKeys,
                pauseKeyDisplay: pauseKeyDisplay,
                resumeKeyDisplay: resumeKeyDisplay,
                togglePauseResume: togglePauseResume,
                silence: silenceConfig,
                recorder: recorder
            )

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
