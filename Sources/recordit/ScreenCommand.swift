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

    @Option(help: "Stop recording after this many seconds. If omitted, press Ctrl-C to stop.")
    var duration: Double?

    mutating func run() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            log("No displays available for capture.")
            throw ExitCode(2)
        }

        let filename = "recordit-screen-\(UUID().uuidString).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let recorder = try ScreenRecorder(outputURL: url, display: display)

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
        print(url.path())

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

final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "recordit.screen.capture")

    init(outputURL: URL, display: SCDisplay) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height
            ]
        )
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
