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
    /// Kept around as a fallback if `playCleanupTrash()` is ever
    /// disabled, but not currently used.
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

    /// Mac "empty trash" style crumple — a low bass thump followed by a
    /// short burst of noise pushed through a descending lowpass sweep.
    /// Mimics the spectral shape of paper crumpling into a bin; not
    /// pixel-identical to macOS but evokes the same feeling.
    static func playCleanupTrash() {
        setupIfNeeded()
        guard isStarted, let buffer = renderTrashCrumple() else { return }
        play(buffer: buffer)
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
        play(buffer: buffer)
    }

    /// Schedule a one-shot buffer through a fresh player node. Each play
    /// gets its own player so concurrent rapid swipes overlap cleanly
    /// instead of clipping each other; the node is detached in the
    /// completion callback so we don't leak.
    private static func play(buffer: AVAudioPCMBuffer) {
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

    /// Synthesize a "ka-thunk + crumple" buffer that evokes the macOS
    /// empty-trash sound. Three layered components, all mixed mono:
    ///
    ///   1. **Bass thump** (0–60ms): a fast-decaying 90 Hz tone — the
    ///      "thunk" you hear as the bag drops into the bin.
    ///   2. **Filtered noise** (0–400ms): white noise pushed through a
    ///      one-pole IIR lowpass whose cutoff descends over time, so the
    ///      texture gets darker as it decays — same spectral shape as
    ///      paper crumpling, where high-frequency content dies off
    ///      faster than the low rumble.
    ///   3. **Exponential envelope** over the whole thing so the tail
    ///      fades naturally.
    ///
    /// Total duration ~500ms. Not a sampled copy of Apple's actual sound,
    /// just a same-shape synthesis.
    private static func renderTrashCrumple() -> AVAudioPCMBuffer? {
        let sampleRate: Double = 44_100
        let durationMs = 500
        let frameCount = AVAudioFrameCount(sampleRate * Double(durationMs) / 1000.0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let totalFrames = Int(frameCount)
        let twoPi = 2.0 * Double.pi

        // Lowpass filter state — one-pole IIR. cutoff is the per-sample
        // smoothing coefficient (0 = full lowpass, 1 = passthrough);
        // we slide it from ~0.6 (bright crumple) down to ~0.05 (dark
        // rumble) over the duration of the buffer.
        var lpState: Double = 0
        // Pre-warm the noise generator with a fixed seed-ish offset so
        // multiple plays sound similar but not identical. Swift's
        // Double.random uses the system RNG, which is fine here.

        let attackFrames = Int(sampleRate * 0.003)  // 3ms attack
        for i in 0..<totalFrames {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(totalFrames)  // 0…1

            // -- 1. Bass thump (90 Hz sine, ~60ms decay) ---------------
            var bass = 0.0
            if t < 0.06 {
                let bassDecay = (0.06 - t) / 0.06
                bass = sin(twoPi * 90.0 * t) * bassDecay * 0.55
            }

            // -- 2. Filtered white noise ------------------------------
            let noise = Double.random(in: -1...1)
            // Cutoff descends from 0.55 → 0.05.
            let alpha = 0.55 - 0.50 * progress
            lpState = lpState + alpha * (noise - lpState)
            let noiseComponent = lpState * 0.85

            // -- 3. Overall envelope (fast attack + exponential decay) -
            let attackEnv = min(1.0, Double(i) / Double(attackFrames))
            let decayEnv  = exp(-progress * 3.2)  // tail fades naturally
            let envelope  = attackEnv * decayEnv

            let mix = (bass + noiseComponent) * envelope
            // Final peak — keep it noticeably louder than the swipe tones
            // since the cleanup chime is a moment-of-completion event.
            channel[i] = Float(mix) * 0.45
        }
        return buffer
    }
}
