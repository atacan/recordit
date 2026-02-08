@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum StreamAudioSourceKind {
    case system
    case microphone
}

enum StreamAudioMixMode {
    case system
    case microphone
    case both

    var capturesSystem: Bool {
        switch self {
        case .system, .both:
            return true
        case .microphone:
            return false
        }
    }

    var capturesMicrophone: Bool {
        switch self {
        case .microphone, .both:
            return true
        case .system:
            return false
        }
    }
}

final class StreamAudioPipeline {
    private final class ConverterState {
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter

        init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            self.inputFormat = inputFormat
            self.converter = converter
        }
    }

    private struct FloatSampleQueue {
        private(set) var samples: [Float] = []
        private(set) var readIndex = 0
        let channels: Int

        var frameCount: Int {
            max(0, (samples.count - readIndex) / channels)
        }

        mutating func append(_ newSamples: [Float]) {
            compactIfNeeded()
            samples.append(contentsOf: newSamples)
        }

        mutating func pop(frames: Int) -> [Float] {
            let requestedSampleCount = frames * channels
            let availableFrames = min(frames, frameCount)
            let availableSampleCount = availableFrames * channels

            var result = [Float](repeating: 0, count: requestedSampleCount)
            if availableSampleCount > 0 {
                let start = readIndex
                let end = readIndex + availableSampleCount
                result.replaceSubrange(0..<availableSampleCount, with: samples[start..<end])
                readIndex = end
            }
            compactIfNeeded()
            return result
        }

        private mutating func compactIfNeeded() {
            guard readIndex > 0 else { return }
            if readIndex >= samples.count {
                samples.removeAll(keepingCapacity: true)
                readIndex = 0
            } else if readIndex > 16_384 {
                samples.removeFirst(readIndex)
                readIndex = 0
            }
        }
    }

    let mode: StreamAudioMixMode
    let sampleRate: Int
    let channels: Int

    private let targetFormat: AVAudioFormat
    private let targetFormatDescription: CMAudioFormatDescription
    private let chunkFrames = 1_024
    private var nextOutputPTS: CMTime?
    private var systemQueue: FloatSampleQueue
    private var microphoneQueue: FloatSampleQueue
    private var converters: [StreamAudioSourceKind: ConverterState] = [:]
    private var loggedPCMFailureSources: Set<StreamAudioSourceKind> = []
    private var loggedConversionFailureSources: Set<StreamAudioSourceKind> = []
    private var loggedEmptyConversionSources: Set<StreamAudioSourceKind> = []

    init(mode: StreamAudioMixMode, sampleRate: Int, channels: Int) throws {
        guard sampleRate > 0 else {
            throw NSError(
                domain: "record.StreamAudioPipeline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio sample rate must be greater than 0."]
            )
        }
        guard channels > 0 else {
            throw NSError(
                domain: "record.StreamAudioPipeline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio channels must be greater than 0."]
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw NSError(
                domain: "record.StreamAudioPipeline",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create target audio format."]
            )
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw NSError(
                domain: "record.StreamAudioPipeline",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio format description (CoreMedia error \(status))."]
            )
        }

        self.mode = mode
        self.sampleRate = sampleRate
        self.channels = channels
        self.targetFormat = format
        self.targetFormatDescription = formatDescription
        self.systemQueue = FloatSampleQueue(channels: channels)
        self.microphoneQueue = FloatSampleQueue(channels: channels)
    }

    func append(sampleBuffer: CMSampleBuffer, source: StreamAudioSourceKind) -> [CMSampleBuffer] {
        guard shouldCapture(source: source) else {
            return []
        }
        guard let inputBuffer = pcmBuffer(from: sampleBuffer) else {
            if !loggedPCMFailureSources.contains(source) {
                loggedPCMFailureSources.insert(source)
                log("Warning: unable to decode \(source == .system ? "system" : "microphone") audio sample buffer.")
            }
            return []
        }
        guard let convertedBuffer = convertToTarget(buffer: inputBuffer, source: source) else {
            if !loggedConversionFailureSources.contains(source) {
                loggedConversionFailureSources.insert(source)
                log("Warning: unable to convert \(source == .system ? "system" : "microphone") audio into mix format.")
            }
            return []
        }

        let samples = interleavedSamples(from: convertedBuffer)
        guard !samples.isEmpty else {
            return []
        }

        if nextOutputPTS == nil {
            nextOutputPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        switch source {
        case .system:
            systemQueue.append(samples)
        case .microphone:
            microphoneQueue.append(samples)
        }

        return drainMixedSampleBuffers()
    }

    private func shouldCapture(source: StreamAudioSourceKind) -> Bool {
        switch source {
        case .system:
            return mode.capturesSystem
        case .microphone:
            return mode.capturesMicrophone
        }
    }

    private func drainMixedSampleBuffers() -> [CMSampleBuffer] {
        guard var pts = nextOutputPTS else {
            return []
        }

        var output: [CMSampleBuffer] = []
        while true {
            let availableFrames = availableFramesForEmit()
            if availableFrames <= 0 {
                break
            }

            let framesToEmit = min(chunkFrames, availableFrames)
            let mixed = mixedSamples(frames: framesToEmit)
            if let sampleBuffer = makeSampleBuffer(samples: mixed, frameCount: framesToEmit, pts: pts) {
                output.append(sampleBuffer)
            }
            pts = CMTimeAdd(pts, CMTime(value: Int64(framesToEmit), timescale: CMTimeScale(sampleRate)))
        }

        nextOutputPTS = pts
        return output
    }

    private func availableFramesForEmit() -> Int {
        switch mode {
        case .system:
            return systemQueue.frameCount
        case .microphone:
            return microphoneQueue.frameCount
        case .both:
            return max(systemQueue.frameCount, microphoneQueue.frameCount)
        }
    }

    private func mixedSamples(frames: Int) -> [Float] {
        switch mode {
        case .system:
            return systemQueue.pop(frames: frames)
        case .microphone:
            return microphoneQueue.pop(frames: frames)
        case .both:
            let system = systemQueue.pop(frames: frames)
            let microphone = microphoneQueue.pop(frames: frames)
            var mixed = [Float](repeating: 0, count: system.count)
            for index in 0..<system.count {
                mixed[index] = Self.mixSample(system: system[index], microphone: microphone[index])
            }
            return mixed
        }
    }

    static func mixSample(system: Float, microphone: Float) -> Float {
        let value = (system + microphone) * 0.5
        return max(-1.0, min(1.0, value))
    }

    private func makeSampleBuffer(samples: [Float], frameCount: Int, pts: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let replaceStatus = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else {
                return OSStatus(unimpErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: targetFormatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: asbdPtr) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(max(0, CMSampleBufferGetNumSamples(sampleBuffer)))
        guard frameCount > 0 else {
            return nil
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let maxBuffers = max(1, Int(inputFormat.channelCount))
        let ablSize = MemoryLayout<AudioBufferList>.size + (maxBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablRaw.deallocate() }
        ablRaw.initializeMemory(as: UInt8.self, repeating: 0, count: ablSize)

        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let srcList = UnsafeMutableAudioBufferListPointer(abl)
        let dstList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let count = min(srcList.count, dstList.count)
        for index in 0..<count {
            guard let src = srcList[index].mData, let dst = dstList[index].mData else {
                continue
            }
            let byteCount = Int(min(srcList[index].mDataByteSize, dstList[index].mDataByteSize))
            memcpy(dst, src, byteCount)
        }

        return pcmBuffer
    }

    private func convertToTarget(buffer: AVAudioPCMBuffer, source: StreamAudioSourceKind) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if isSameFormat(lhs: inputFormat, rhs: targetFormat) {
            return buffer
        }

        let converterState: ConverterState
        if let current = converters[source], isSameFormat(lhs: current.inputFormat, rhs: inputFormat) {
            converterState = current
        } else {
            guard let newState = ConverterState(inputFormat: inputFormat, outputFormat: targetFormat) else {
                return nil
            }
            converters[source] = newState
            converterState = newState
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let estimated = Double(buffer.frameLength) * ratio + 64
        let outputCapacity = AVAudioFrameCount(max(1, Int(estimated.rounded(.up))))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var consumed = false
        var convertError: NSError?
        let status = converterState.converter.convert(to: output, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if output.frameLength > 0 {
                return output
            }
            if !loggedEmptyConversionSources.contains(source) {
                loggedEmptyConversionSources.insert(source)
                log("Warning: \(source == .system ? "system" : "microphone") audio conversion produced no frames.")
            }
            return nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func interleavedSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.isInterleaved,
              let mData = buffer.audioBufferList.pointee.mBuffers.mData else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let sampleCount = frameCount * channels
        guard sampleCount > 0 else {
            return []
        }
        let pointer = mData.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
    }

    private func isSameFormat(lhs: AVAudioFormat, rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}
