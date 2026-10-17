import AppKit
import AVFoundation
import Combine
import WheelieCore

/// Plays Wheelie's synthesized sounds with AVAudioEngine.
///
/// Everything audio happens on one serial queue, so the main thread (and the
/// wheel's animation) never waits for the engine. Buffers are rendered once per
/// output sample rate; the engine starts on first use and stops after a quiet
/// spell so the audio hardware isn't kept awake.
final class SoundPlayer: @unchecked Sendable {
    static let shared = SoundPlayer()

    private let queue = DispatchQueue(label: "wheelie.shell.sound", qos: .userInteractive)
    private let idleTimeout: TimeInterval = 20
    private let minimumTickGap: TimeInterval = 0.025

    // Queue-confined state.
    private var engine: AVAudioEngine?
    private var tickPlayers: [AVAudioPlayerNode] = []
    private var chimePlayer: AVAudioPlayerNode?
    private var tickBuffers: [AVAudioPCMBuffer] = []
    private var chimeBuffers: [WheelieSound: AVAudioPCMBuffer] = [:]
    private var renderedSampleRate: Double = 0
    private var nextTick = 0
    private var lastTick: CFAbsoluteTime = 0
    private var idleGeneration = 0
    private var configurationObserver: NSObjectProtocol?

    private init() {}

    func play(_ sound: WheelieSound) {
        queue.async { self.playOnQueue(sound) }
    }

    /// Starts the engine ahead of time (e.g. when the wheel is about to be used).
    func warmUp() {
        queue.async {
            if self.ensureEngine() { self.scheduleIdleStop() }
        }
    }

    // MARK: Queue

    private func playOnQueue(_ sound: WheelieSound) {
        if sound == .tick {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastTick >= minimumTickGap else { return }
            lastTick = now
        }
        guard ensureEngine() else { return }
        switch sound {
        case .tick:
            guard !tickPlayers.isEmpty, !tickBuffers.isEmpty else { return }
            let player = tickPlayers[nextTick % tickPlayers.count]
            let buffer = tickBuffers[nextTick % tickBuffers.count]
            nextTick &+= 1
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        case .success, .failure:
            guard let player = chimePlayer, let buffer = chimeBuffers[sound] else { return }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
        scheduleIdleStop()
    }

    private func ensureEngine() -> Bool {
        if let engine, engine.isRunning { return true }
        teardown()

        let engine = AVAudioEngine()
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        if sampleRate != renderedSampleRate { render(format: format) }

        let ticks = (0..<3).map { _ in AVAudioPlayerNode() }
        let chime = AVAudioPlayerNode()
        for node in ticks + [chime] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[Wheelie] Sound engine failed to start: %@", error.localizedDescription)
            return false
        }
        (ticks + [chime]).forEach { $0.play() }

        self.engine = engine
        tickPlayers = ticks
        chimePlayer = chime
        // Output device changed (headphones, AirPlay…): the engine stops; rebuild on next use.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.teardown() }
        }
        return true
    }

    private func render(format: AVAudioFormat) {
        tickBuffers = WheelieSound.tickPitches.compactMap {
            makeBuffer(ToneSynth.render(WheelieSound.tick.spec(pitch: $0), sampleRate: format.sampleRate), format: format)
        }
        chimeBuffers = [:]
        for sound in [WheelieSound.success, .failure] {
            chimeBuffers[sound] = makeBuffer(ToneSynth.render(sound.spec(), sampleRate: format.sampleRate), format: format)
        }
        renderedSampleRate = format.sampleRate
    }

    private func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    private func scheduleIdleStop() {
        idleGeneration &+= 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + idleTimeout) {
            guard generation == self.idleGeneration else { return }
            self.teardown()
        }
    }

    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        (tickPlayers + [chimePlayer].compactMap { $0 }).forEach { $0.stop() }
        engine.stop()
        self.engine = nil
        tickPlayers = []
        chimePlayer = nil
    }
}

/// Sounds and haptics for wheel highlights and finished jobs (Settings › General › Sounds).
@MainActor
final class ShellFeedback {
    static let shared = ShellFeedback()

    private var observers: [AnyCancellable] = []
    private var enabled = true

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        readSetting()
        observers.append(ShellFeature.observe(UserDefaults.didChangeNotification) { [weak self] _ in
            self?.readSetting()
        })
        observers.append(ShellFeature.observe(.wheelieHighlightChanged) { [weak self] note in
            guard let self, self.enabled, note.object as? String != nil else { return }
            SoundPlayer.shared.play(.tick)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        })
        // The wheel panel just appeared: start the engine (off the main thread)
        // while it animates in, so the first tick isn't late.
        observers.append(ShellFeature.observe(NSWindow.didChangeOcclusionStateNotification) { [weak self] note in
            guard let self, self.enabled, let panel = note.object as? WheelPanel,
                  panel.occlusionState.contains(.visible) else { return }
            SoundPlayer.shared.warmUp()
        })
    }

    /// Called by the job monitor when a job ends.
    func jobFinished(_ feedback: JobBoard.Feedback?) {
        guard enabled, let feedback else { return }
        SoundPlayer.shared.play(feedback == .success ? .success : .failure)
    }

    /// Settings' "Preview" button: plays regardless of the current toggle state.
    func preview() {
        SoundPlayer.shared.play(.tick)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { SoundPlayer.shared.play(.success) }
    }

    private func readSetting() {
        let value = AppServices.shared.bool(SettingsKey.playSounds, default: true)
        if value != enabled {
            enabled = value
            if value { SoundPlayer.shared.warmUp() }
        }
    }
}
