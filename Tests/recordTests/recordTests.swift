import Foundation
import CoreMedia
import ScreenCaptureKit
import Testing
@testable import record

private func parseAudioCommand(_ arguments: [String]) throws -> AudioCommand {
    try AudioCommand.parseAsRoot(arguments) as! AudioCommand
}

@Test func parseAudioSourceOption() throws {
    let command = try parseAudioCommand(["--source", "both"])
    #expect(command.source == .both)
}

@Test func systemSourceRejectsLinearPCM() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "system", "--format", "linearPCM"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func bothSourceRejectsSilenceOptions() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "both", "--silence-db", "-50", "--silence-duration", "2"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func micSourceRejectsDisplaySelector() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "mic", "--display", "primary"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func micSourceRejectsSystemGain() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "mic", "--system-gain", "1.5"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func systemGainMustBePositive() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "both", "--system-gain", "0"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func sourceDefaultsMatchDesign() throws {
    let command = try parseAudioCommand([])

    #expect(command.defaultFormat(for: .mic) == .linearPCM)
    #expect(command.defaultFormat(for: .system) == .aac)
    #expect(command.defaultFormat(for: .both) == .aac)

    #expect(command.defaultSampleRate(for: .mic) == 44_100)
    #expect(command.defaultSampleRate(for: .system) == 48_000)
    #expect(command.defaultChannels(for: .mic) == 1)
    #expect(command.defaultChannels(for: .both) == 2)
}

@Test func outputExtensionMappingIsStable() throws {
    let commandCAF = try parseAudioCommand(["--output", NSTemporaryDirectory() + "/record-test-\(UUID().uuidString)"])
    let cafURL = try commandCAF.resolveOutputURL(extension: AudioCommand.AudioFormat.linearPCM.fileExtension)
    #expect(cafURL.pathExtension == "caf")

    let commandM4A = try parseAudioCommand(["--output", NSTemporaryDirectory() + "/record-test-\(UUID().uuidString)"])
    let m4aURL = try commandM4A.resolveOutputURL(extension: AudioCommand.AudioFormat.aac.fileExtension)
    #expect(m4aURL.pathExtension == "m4a")
}

@Test func mixerClipsAndAverages() {
    #expect(StreamAudioPipeline.mixSample(system: 1.0, microphone: 1.0) == 1.0)
    #expect(StreamAudioPipeline.mixSample(system: -1.0, microphone: -1.0) == -1.0)

    let neutral = StreamAudioPipeline.mixSample(system: 0.5, microphone: -0.5)
    #expect(abs(neutral) < 0.0001)

    let boosted = StreamAudioPipeline.mixSample(system: 0.4, microphone: 0.2, systemGain: 2.0)
    #expect(abs(boosted - 0.5) < 0.0001)
}

@Test func screenFrameStatusGuardKeepsOnlyCompleteFrames() {
    #expect(ScreenFrameGuards.shouldAppendVideoFrame(frameStatusRawValue: nil))
    #expect(ScreenFrameGuards.shouldAppendVideoFrame(frameStatusRawValue: SCFrameStatus.complete.rawValue))
    #expect(!ScreenFrameGuards.shouldAppendVideoFrame(frameStatusRawValue: SCFrameStatus.idle.rawValue))
    #expect(!ScreenFrameGuards.shouldAppendVideoFrame(frameStatusRawValue: SCFrameStatus.started.rawValue))
    #expect(ScreenFrameGuards.shouldAppendVideoFrame(frameStatusRawValue: Int.max))
}

@Test func screenFrameTimestampGuardRequiresStrictIncrease() {
    let t1 = CMTime(value: 1_000, timescale: 1_000)
    let t2 = CMTime(value: 1_001, timescale: 1_000)
    let t0 = CMTime(value: 999, timescale: 1_000)

    #expect(ScreenFrameGuards.shouldAppendVideoFrame(lastVideoPTS: nil, currentPTS: t1))
    #expect(ScreenFrameGuards.shouldAppendVideoFrame(lastVideoPTS: t1, currentPTS: t2))
    #expect(!ScreenFrameGuards.shouldAppendVideoFrame(lastVideoPTS: t1, currentPTS: t1))
    #expect(!ScreenFrameGuards.shouldAppendVideoFrame(lastVideoPTS: t1, currentPTS: t0))
}
