import AppKit
import AVFAudio

/// Selection changes, not mouse-move frequency, drive feedback. Visual updates
/// remain immediate even when very fast changes are acoustically coalesced.
struct FeedbackGate {
    private(set) var selection: Int?
    private var lastTick = -Double.infinity
    mutating func select(_ index: Int?, at time: TimeInterval) -> Bool {
        guard index != selection else { return false }
        selection = index
        guard index != nil, time - lastTick >= 0.045 else { return false }
        lastTick = time
        return true
    }
}

enum FeedbackSound {
    case tick, confirm
    static let sampleRate = 44_100

    /// Original, quiet tactile transients; no audio assets from Tangerine.
    var samples: [Int16] {
        let duration = self == .tick ? 0.018 : 0.048
        let count = Int(duration * Double(Self.sampleRate))
        var noise: UInt32 = 0x5A17
        return (0..<count).map { index in
            let t = Double(index) / Double(Self.sampleRate)
            let attack = min(1, t / 0.0008)
            let fade = min(1, Double(count - 1 - index) / 35)
            noise = 1_664_525 &* noise &+ 1_013_904_223
            let grain = Double(noise >> 16) / 32768 - 1
            let frequency = self == .tick ? 1550.0 : 980.0
            let decay = self == .tick ? 340.0 : 115.0
            let tone = sin(2 * .pi * frequency * t) * 0.65 + sin(2 * .pi * frequency * 1.71 * t) * 0.2 + grain * 0.15
            return Int16(tone * attack * fade * exp(-decay * t) * 11_000)
        }
    }

    var wave: Data { Self.wave(samples: samples) }
    static func wave(samples: [Int16]) -> Data {
        var data = Data()
        func string(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        string("RIFF"); number(UInt32(36 + samples.count * 2)); string("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(sampleRate))
        number(UInt32(sampleRate * 2)); number(UInt16(2)); number(UInt16(16))
        string("data"); number(UInt32(samples.count * 2))
        for sample in samples { number(sample) }
        return data
    }
    static var demonstration: Data {
        let pause = [Int16](repeating: 0, count: sampleRate / 5)
        let samples = pause + (0..<4).flatMap { _ in FeedbackSound.tick.samples + pause } + FeedbackSound.confirm.samples + pause
        return wave(samples: samples)
    }
}

@MainActor final class InteractionFeedback {
    static let shared = InteractionFeedback()
    private var ticks: [AVAudioPlayer] = []
    private var confirmation: AVAudioPlayer?
    private var voice = 0
    private(set) var error: String?

    func prepare() {
        guard ticks.isEmpty else { return }
        do {
            ticks = try (0..<2).map { _ in try AVAudioPlayer(data: FeedbackSound.tick.wave) }
            confirmation = try AVAudioPlayer(data: FeedbackSound.confirm.wave)
            for player in ticks + [confirmation].compactMap({ $0 }) { player.prepareToPlay() }
            error = nil
        } catch { self.error = error.localizedDescription; ticks = []; confirmation = nil }
    }
    @discardableResult func play(_ sound: FeedbackSound, preferences: Preferences) -> Bool {
        guard preferences.soundsEnabled, preferences.soundVolume > 0 else { return true }
        prepare()
        let player: AVAudioPlayer?
        if sound == .tick, !ticks.isEmpty { player = ticks[voice % ticks.count]; voice += 1 }
        else { player = confirmation }
        guard let player else { return false }
        player.currentTime = 0
        player.volume = Float(min(1, max(0, preferences.soundVolume)))
        return player.play()
    }
    func selection(preferences: Preferences) {
        play(.tick, preferences: preferences)
        if preferences.hapticsEnabled { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    func confirm(preferences: Preferences) { play(.confirm, preferences: preferences) }
}
