import XCTest
import AppKit
import AVFAudio
@testable import ZawiyaApp

final class FeedbackTests: XCTestCase {
    func testHoverOnlyTicksWhenSelectionChangesAndCoalescesFastChanges() {
        var gate = FeedbackGate()
        XCTAssertFalse(gate.select(nil, at: 1))
        XCTAssertTrue(gate.select(0, at: 1))
        XCTAssertFalse(gate.select(0, at: 2)) // No continuous ticking on a stationary target.
        XCTAssertTrue(gate.select(1, at: 2))
        XCTAssertFalse(gate.select(2, at: 2.01)) // Pointer can still visually move.
        XCTAssertEqual(gate.selection, 2)
        XCTAssertTrue(gate.select(3, at: 2.06))
        XCTAssertFalse(gate.select(nil, at: 2.1))
        XCTAssertTrue(gate.select(3, at: 2.2))
    }
    func testGeneratedFeedbackIsShortBoundedAndHasSilentEndpoints() throws {
        for sound in [FeedbackSound.tick, .confirm] {
            let samples = sound.samples
            XCTAssertGreaterThan(samples.count, 400)
            XCTAssertLessThan(samples.count, FeedbackSound.sampleRate / 10)
            XCTAssertEqual(samples.first, 0); XCTAssertEqual(samples.last, 0)
            XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, 12_000)
            XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 1_000)
            let player = try AVAudioPlayer(data: sound.wave)
            XCTAssertEqual(player.duration, Double(samples.count) / Double(FeedbackSound.sampleRate), accuracy: 0.001)
            XCTAssertEqual(player.numberOfChannels, 1)
        }
    }
    func testWaveHeaderAndDemonstrationDecodeWithoutExternalAssets() throws {
        let wave = FeedbackSound.tick.wave
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wave.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(wave.count, 44 + FeedbackSound.tick.samples.count * 2)
        let demo = try AVAudioPlayer(data: FeedbackSound.demonstration)
        XCTAssertGreaterThan(demo.duration, 1); XCTAssertLessThan(demo.duration, 2)
    }
    func testCommonWheelsRemainCompactWithAllTargetsAndReadableHitAreas() {
        for count in 1...9 {
            let geometry = WheelGeometry(count: count)
            XCTAssertLessThanOrEqual(geometry.size.width, 380)
            XCTAssertEqual(geometry.frames.count, count)
            XCTAssertTrue(geometry.frames.allSatisfy { $0.width >= 44 && $0.height >= 44 })
        }
    }
    @MainActor func testMutedFeedbackDoesNotInitializeAudioAndPreferencesCanBeIndependent() {
        let preferences = Preferences(persist: false)
        preferences.soundsEnabled = false; preferences.hapticsEnabled = false
        let feedback = InteractionFeedback()
        XCTAssertTrue(feedback.play(.tick, preferences: preferences))
        XCTAssertNil(feedback.error)
        preferences.animationsEnabled = false; preferences.soundsEnabled = true
        XCTAssertTrue(preferences.soundsEnabled); XCTAssertFalse(preferences.nativeMotion)
    }
}
