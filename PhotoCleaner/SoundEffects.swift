import AVFoundation

/// Lightweight synthesized swipe / undo / cleanup sounds — direct port of
/// the Chrome extension's WebAudio tones (content.js:54). No bundled audio
/// files; each sound is a few hundred ms of sine/triangle wave generated
/// on-the-fly into a PCM buffer and played through `AVAudioEngine`.
///
/// Why synthesized: matches the extension's frequencies/durations exactly
/// so the two products feel identical, keeps the app bundle small, and
/// dodges all the localization / format compatibility issues that come
/// with audio file assets.
///
/// Audio session is `.ambient` with `.mixWithOthers` — respects the
/// user's silent-mode switch (no audio when silenced) AND plays alongside
/// any music they've got going.
enum SoundEffects {

    enum Waveform {
        case sine, triangle
    }

    // MARK: - Public API

    /// "Keep" swipe — upper note. Right-swipe in the triage deck.
    static func playSwipeKeep() {
        playTone(frequency: 660, durationMs: 100, waveform: .sine, peak: 0.18)
    }

    /// "Delete" swipe — lower note. Left-swipe in the triage deck.
    static func playSwipeDelete() {
        playTone(frequency: 330, durationMs: 120, waveform: .sine, peak: 0.22)
    }

    /// Two-note descending swoop — Undo button or shake gesture.
    static func playUndo() {
        playTone(frequency: 880, durationMs: 70, waveform: .sine, peak: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            playTone(frequency: 440, durationMs: 100, waveform: .sine, peak: 0.18)
        }
    }

    /// C-E-G triangle chime — cleanup completed successfully.
    static func playCleanupDone() {
        // Notes: (frequency Hz, duration ms, start delay s).
        let notes: [(Double, Int, Double)] = [
            (523.25, 140, 0.00),   // C5
            (659.25, 140, 0.13),   // E5
            (783.99, 220, 0.27)    // G5
        ]
        for (freq, dur, delay) in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                playTone(frequency: freq, durationMs: dur, waveform: .triangle, peak: 0.25)
            }
        }
    }

    // MARK: - Engine setup (lazy)

    private static let engine = AVAudioEngine()
    private static let mixer  = AVAudioMixerNode()
    private static var isStarted = false
    private static let setupLock = NSLock()

    /// Idempotent. Configures the audio session and starts the engine on
    /// first call. Subsequent calls are no-ops.
    private static func setupIfNeeded() {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard !isStarted else { return }

        // .ambient + .mixWithOthers: plays only when the silent switch is
        // off, doesn't pause the user's music. Matches what you'd expect
        // from a triage / cleanup app — system-feedback-y, not media-y.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .ambient,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Best-effort. If session setup fails, engine.start() below
            // will probably also fail and we silently skip the sound.
        }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
            isStarted = true
        } catch {
            // Leave isStarted=false so we retry next time.
        }
    }

    // MARK: - Tone generation + playback

    private static func playTone(frequency: Double, durationMs: Int, waveform: Waveform, peak: Float) {
        setupIfNeeded()
        guard isStarted,
              let buffer = renderTone(
                frequency: frequency,
                durationMs: durationMs,
                waveform: waveform,
                peak: peak
              )
        else { return }

        // Each play gets its own player node so concurrent rapid swipes
        // overlap cleanly instead of clipping each other. Detached in the
        // completion callback so we don't leak.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: buffer.format)
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { _ in
            DispatchQueue.main.async {
                player.stop()
                engine.disconnectNodeOutput(player)
                engine.detach(player)
            }
        }
        player.play()
    }

    /// Build a single-channel PCM buffer containing a `durationMs` tone at
    /// `frequency`, with a short attack + release envelope so it doesn't
    /// click on start/stop. `peak` is the maximum signed amplitude in the
    /// linear -1.0…+1.0 sample range.
    private static func renderTone(
        frequency: Double,
        durationMs: Int,
        waveform: Waveform,
        peak: Float
    ) -> AVAudioPCMBuffer? {
        let sampleRate: Double = 44_100
        let frameCount = AVAudioFrameCount(sampleRate * Double(durationMs) / 1000.0)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let totalFrames = Int(frameCount)
        // 5ms attack + 50ms release. Clip to total duration if the tone
        // is shorter than the envelope.
        let attackFrames  = min(totalFrames / 4, Int(sampleRate * 0.005))
        let releaseFrames = min(totalFrames / 2, Int(sampleRate * 0.050))
        let twoPi = 2.0 * Double.pi

        for i in 0..<totalFrames {
            let t = Double(i) / sampleRate
            // Raw waveform sample, in -1…+1.
            let raw: Double
            switch waveform {
            case .sine:
                raw = sin(twoPi * frequency * t)
            case .triangle:
                // Phase in [0, 1) for one cycle of the wave.
                let phase = (frequency * t).truncatingRemainder(dividingBy: 1.0)
                // Triangle: 0→1 over [0, 0.5), 1→0 over [0.5, 1), mapped to -1…+1.
                raw = phase < 0.5
                    ? (4.0 * phase - 1.0)
                    : (3.0 - 4.0 * phase)
            }

            // Linear attack / release envelope so there's no audible click
            // at the buffer boundaries.
            var envelope: Double = 1.0
            if i < attackFrames {
                envelope = Double(i) / Double(attackFrames)
            } else if i >= totalFrames - releaseFrames {
                envelope = Double(totalFrames - i) / Double(releaseFrames)
            }

            channel[i] = Float(raw * envelope) * peak
        }
        return buffer
    }
}
