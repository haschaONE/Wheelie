import Foundation

/// One overtone of a tone: frequency `ratio` × the fundamental at `gain`.
/// Higher partials usually die out faster (`decayScale` < 1).
public struct Partial: Sendable, Equatable {
    public var ratio: Double
    public var gain: Double
    public var decayScale: Double

    public init(_ ratio: Double, gain: Double, decayScale: Double = 1) {
        self.ratio = ratio
        self.gain = gain
        self.decayScale = decayScale
    }
}

/// A single struck note: smooth attack, exponential decay, and a short fade
/// at the end so it always lands exactly on silence (no click).
public struct Tone: Sendable, Equatable {
    public var frequency: Double
    /// Offset from the start of the sound, in seconds.
    public var start: TimeInterval
    public var duration: TimeInterval
    public var amplitude: Double
    public var attack: TimeInterval
    /// Exponential decay time constant (amplitude falls to 37 % after this long).
    public var decay: TimeInterval
    public var partials: [Partial]
    /// Pitch at the end relative to the start (exponential glide); 1 = steady.
    public var glide: Double

    public init(frequency: Double, start: TimeInterval = 0, duration: TimeInterval, amplitude: Double = 1,
                attack: TimeInterval = 0.004, decay: TimeInterval, partials: [Partial] = [Partial(1, gain: 1)],
                glide: Double = 1) {
        self.frequency = frequency
        self.start = start
        self.duration = duration
        self.amplitude = amplitude
        self.attack = attack
        self.decay = decay
        self.partials = partials
        self.glide = glide
    }

    public var end: TimeInterval { start + duration }
}

public struct SoundSpec: Sendable, Equatable {
    public var tones: [Tone]
    /// The rendered sound is scaled so its loudest sample is exactly this (0…1).
    public var peak: Double

    public init(tones: [Tone], peak: Double) {
        self.tones = tones
        self.peak = min(max(peak, 0), 1)
    }

    public var duration: TimeInterval { tones.map(\.end).max() ?? 0 }

    public func frameCount(sampleRate: Double) -> Int {
        Int((duration * sampleRate).rounded(.up))
    }
}

/// Renders `SoundSpec`s to mono Float samples once, up front, so playback is
/// just scheduling a buffer.
public enum ToneSynth {
    public static func render(_ spec: SoundSpec, sampleRate: Double) -> [Float] {
        let count = spec.frameCount(sampleRate: sampleRate)
        guard count > 0, sampleRate > 0 else { return [] }
        var mix = [Double](repeating: 0, count: count)

        for tone in spec.tones where tone.duration > 0 && tone.frequency > 0 {
            let first = Int((tone.start * sampleRate).rounded())
            let length = min(Int((tone.duration * sampleRate).rounded()), count - first)
            guard first >= 0, length > 1 else { continue }
            // The tail fade keeps the end sample-exact at zero regardless of decay.
            let fade = min(max(tone.duration * 0.15, 0.003), tone.duration / 2)
            let decay = max(tone.decay, 1e-4)
            var phase = 0.0
            for n in 0..<length {
                let t = Double(n) / sampleRate
                let progress = Double(n) / Double(length - 1)
                var envelope = tone.amplitude
                if tone.attack > 0, t < tone.attack {
                    envelope *= 0.5 - 0.5 * cos(Double.pi * t / tone.attack)
                }
                let remaining = tone.duration * (1 - progress)
                if remaining < fade {
                    envelope *= 0.5 - 0.5 * cos(Double.pi * remaining / fade)
                }
                var sample = 0.0
                for partial in tone.partials {
                    sample += partial.gain * exp(-t / (decay * max(partial.decayScale, 1e-3))) * sin(phase * partial.ratio)
                }
                mix[first + n] += envelope * sample
                let frequency = tone.frequency * pow(tone.glide, progress)
                phase += 2 * Double.pi * frequency / sampleRate
            }
        }

        let loudest = mix.reduce(0) { max($0, abs($1)) }
        let gain = loudest > 0 ? spec.peak / loudest : 0
        return mix.map { Float($0 * gain) }
    }
}

/// Wheelie's three feedback sounds.
public enum WheelieSound: CaseIterable, Sendable {
    /// Highlighted petal changed: a tiny, soft wooden tick (~30 ms).
    case tick
    /// Job wrote files: a two-note rising bell.
    case success
    /// Job failed: two muted, falling notes.
    case failure

    /// Slight pitch variations for consecutive ticks, so a sweep across petals
    /// doesn't sound like a machine gun.
    public static let tickPitches: [Double] = [1.0, 1.06, 0.95]

    public func spec(pitch: Double = 1) -> SoundSpec {
        switch self {
        case .tick:
            return SoundSpec(tones: [
                Tone(frequency: 1_700 * pitch, duration: 0.032, attack: 0.0012, decay: 0.0075,
                     partials: [Partial(1, gain: 1), Partial(2.02, gain: 0.22, decayScale: 0.5)],
                     glide: 0.86),
            ], peak: 0.2)
        case .success:
            let bell = [Partial(1, gain: 1), Partial(2, gain: 0.26, decayScale: 0.6),
                        Partial(3, gain: 0.08, decayScale: 0.4), Partial(4.18, gain: 0.03, decayScale: 0.3)]
            return SoundSpec(tones: [
                Tone(frequency: 783.99 * pitch, duration: 0.42, amplitude: 0.85, attack: 0.004, decay: 0.15, partials: bell),
                Tone(frequency: 1_046.5 * pitch, start: 0.085, duration: 0.55, attack: 0.004, decay: 0.2, partials: bell),
            ], peak: 0.32)
        case .failure:
            let soft = [Partial(1, gain: 1), Partial(3, gain: 0.1, decayScale: 0.6), Partial(5, gain: 0.03, decayScale: 0.4)]
            return SoundSpec(tones: [
                Tone(frequency: 329.63 * pitch, duration: 0.3, attack: 0.008, decay: 0.12, partials: soft, glide: 0.985),
                Tone(frequency: 261.63 * pitch, start: 0.13, duration: 0.4, attack: 0.008, decay: 0.15, partials: soft, glide: 0.98),
            ], peak: 0.3)
        }
    }
}
