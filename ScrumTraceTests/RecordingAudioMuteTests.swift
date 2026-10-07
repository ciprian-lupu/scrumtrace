import AppKit
import AVFoundation
import XCTest
@testable import ScrumTrace

final class RecordingAudioMuteTests: XCTestCase {
    func testIndependentMutesAndDelayedBuffers() {
        var mute = RecordingAudioMute()
        mute.set(all: false, microphone: true, at: 10)
        XCTAssertTrue(mute.shouldSilence(microphone: true, start: 11, duration: 1))
        XCTAssertFalse(mute.shouldSilence(microphone: false, start: 11, duration: 1))
        mute.set(all: true, microphone: true, at: 12)
        XCTAssertTrue(mute.shouldSilence(microphone: false, start: 13, duration: 1))
        mute.set(all: false, microphone: true, at: 14)
        XCTAssertFalse(mute.shouldSilence(microphone: false, start: 15, duration: 1))
        XCTAssertTrue(mute.shouldSilence(microphone: true, start: 15, duration: 1))
        mute.set(all: false, microphone: false, at: 16)
        XCTAssertFalse(mute.shouldSilence(microphone: true, start: 17, duration: 1))
        XCTAssertTrue(mute.shouldSilence(microphone: true, start: 11, duration: 1), "Delayed mic buffers stay silent after unmute")
        XCTAssertTrue(mute.shouldSilence(microphone: false, start: 13, duration: 0.1))
        XCTAssertTrue(mute.shouldSilence(microphone: false, start: 11.99, duration: 0.02), "Boundary buffers are silenced conservatively")
        XCTAssertFalse(mute.shouldSilence(microphone: false, start: 14, duration: 0.1))
    }

    func testAllMuteRetainsMicChoiceChangedDuringGeneralMute() {
        var mute = RecordingAudioMute()
        mute.set(all: true, microphone: false, at: 1)
        mute.set(all: true, microphone: true, at: 2)
        mute.set(all: false, microphone: true, at: 3)
        XCTAssertTrue(mute.shouldSilence(microphone: true, start: 4, duration: 1))
        XCTAssertFalse(mute.shouldSilence(microphone: false, start: 4, duration: 1))
    }

    func testSilentCopyPreservesPCMFormatFramesTimingAndOriginalBytes() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        var data: CMBlockBuffer?
        let count = 480
        let bytes = count * 2 * MemoryLayout<Float>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &data), noErr)
        let block = try XCTUnwrap(data)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 42, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: 123, timescale: 1), decodeTimeStamp: .invalid)
        var original: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &original), noErr)
        let input = try XCTUnwrap(original)
        let silent = try XCTUnwrap(RecordingAudioMute.silentCopy(of: input))
        XCTAssertEqual(CMSampleBufferGetNumSamples(silent), count)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(silent), CMSampleBufferGetPresentationTimeStamp(input))
        XCTAssertEqual(CMSampleBufferGetDuration(silent), CMSampleBufferGetDuration(input))
        var actual = [UInt8](repeating: 255, count: bytes)
        let silentData = try XCTUnwrap(CMSampleBufferGetDataBuffer(silent))
        XCTAssertEqual(CMBlockBufferCopyDataBytes(silentData, atOffset: 0, dataLength: bytes, destination: &actual), noErr)
        XCTAssertTrue(actual.allSatisfy { $0 == 0 })
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: &actual), noErr)
        XCTAssertTrue(actual.allSatisfy { $0 == 42 }, "Do not modify capture-owned memory")
    }

    func testFallbackPCMSilenceCoversEveryChannelAndPreservesLength() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: interleaved))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                memset(try XCTUnwrap(audio.mData), 55, Int(audio.mDataByteSize))
            }
            RecordingAudioMute.silencePCM(buffer)
            XCTAssertEqual(buffer.frameLength, 128)
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let bytes = try XCTUnwrap(audio.mData).assumingMemoryBound(to: UInt8.self)
                XCTAssertTrue(UnsafeBufferPointer(start: bytes, count: Int(audio.mDataByteSize)).allSatisfy { $0 == 0 })
            }
        }
    }

    @MainActor
    func testHUDButtonsToggleIndependentlyAndRemainAvailableWhenMinified() throws {
        let id = "mute-hud-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        defer { defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: root) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        controller.phase = .recording
        let hud = RecordingHUDWindow(controller: controller, defaults: defaults)
        hud.isReleasedWhenClosed = false
        defer { hud.orderOut(nil) }
        hud.setVisible(true)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = try XCTUnwrap(hud.contentView)
        let buttons = views(content).compactMap { $0 as? NSButton }
        let mic = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "hud.mute.mic" })
        let all = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "hud.mute.all" })
        mic.performClick(nil)
        all.performClick(nil)
        all.performClick(nil)
        XCTAssertTrue(controller.microphoneMuted)
        XCTAssertFalse(controller.allAudioMuted)
        XCTAssertEqual(mic.attributedTitle.string, "Unmute mic")
        if let path = ProcessInfo.processInfo.environment["SCRUMTRACE_MUTE_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("hud-mic-muted.png"))
            }
        }
        hud.setMinified(true)
        XCTAssertFalse(mic.isHidden)
        XCTAssertFalse(all.isHidden)
        XCTAssertTrue(mic.isEnabled)
        mic.performClick(nil)
        XCTAssertFalse(controller.isMicrophoneEffectivelyMuted)
    }

    @MainActor
    func testControllerMuteDoesNotPauseVideoAndHoldToTalkStaysBlockedOnResume() throws {
        let id = "mute-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        defer { defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: root) }
        let controller = SessionController(settings: AppSettings(defaults: defaults, keyStore: .empty), vault: SessionVault(rootURL: root))
        controller.toggleAllAudioMute()
        XCTAssertFalse(controller.allAudioMuted, "Ignore controls outside capture")
        controller.phase = .recording
        controller.toggleMicrophoneMute()
        controller.toggleAllAudioMute()
        controller.toggleAllAudioMute()
        XCTAssertTrue(controller.microphoneMuted)
        XCTAssertEqual(controller.phase, .recording)
        controller.phase = .paused
        controller.toggleMicrophoneMute()
        XCTAssertFalse(controller.isMicrophoneEffectivelyMuted)
        XCTAssertEqual(controller.phase, .paused)
        let talk = ShotTalkState(screenshot: NSImage(size: NSSize(width: 16, height: 16)),
            transcriber: WhisperTranscriber(), whisperModel: WhisperTranscriber.defaultStoredModel,
            allowsNewCapture: { true }, onSave: { _, _, _ in })
        talk.setMicrophoneMuted(true)
        talk.applyCaptureGate(.recording)
        XCTAssertFalse(talk.canTalk)
        talk.setMicrophoneMuted(false)
        XCTAssertTrue(talk.canTalk)
    }
}
