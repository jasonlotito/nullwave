import AVFoundation
import Synchronization

/// Stateful, allocation-free noise synthesis used directly by the audio render thread.
final class NoiseGenerator: @unchecked Sendable {
    static let envelopeDurationSeconds = 0.04

    private let kind: NoiseKind
    private let sampleRate: Double
    private let darkFirstAlpha: Float
    private let darkSecondAlpha: Float
    private let grayLowAlpha: Float
    private let grayMidAlpha: Float
    private let deepLowAlpha: Float
    private let deepLowerAlpha: Float
    private let fanBodyAlpha: Float
    private let fanLowAlpha: Float
    private let cabinAirAlpha: Float
    private let cabinRumbleAlpha: Float
    private let oceanBodyAlpha: Float
    private let oceanLowerAlpha: Float
    private let envelopeGainStep: Float
    private let volumeRequest: Atomic<UInt64>
    private let fadeOutRequested = Atomic(false)
    private let fadeOutCompleted = Atomic(false)
    private var randomState: UInt64 = 0x4d595df4d0f33173
    private var envelopeGain = Float.zero
    private var isFadingOut = false
    private var activeVolumeRequest: UInt64
    private var outputGain: Float
    private var outputGainTarget: Float
    private var outputGainStep = Float.zero
    private var outputGainFramesRemaining = 0

    private var brown = Float.zero
    private var darkLow = Float.zero
    private var darkLower = Float.zero
    private var previousWhite = Float.zero
    private var secondPreviousWhite = Float.zero
    private var grayLow = Float.zero
    private var grayMid = Float.zero
    private var deepLow = Float.zero
    private var deepLower = Float.zero
    private var fanBody = Float.zero
    private var fanLow = Float.zero
    private var cabinAir = Float.zero
    private var cabinRumble = Float.zero
    private var oceanBody = Float.zero
    private var oceanLower = Float.zero
    private var tonePhase = Double.zero
    private var swellPhase = Double.zero

    // Paul Kellet's economical pink-noise filter state.
    private var pink0 = Float.zero
    private var pink1 = Float.zero
    private var pink2 = Float.zero

    init(
        kind: NoiseKind,
        sampleRate: Double,
        initialVolume: Float = 1,
        startsSilently: Bool = true
    ) {
        let clampedVolume = min(max(initialVolume, 0), 1)
        let initialVolumeRequest = Self.packedVolumeRequest(
            volume: clampedVolume,
            rampFrames: 0
        )
        self.kind = kind
        self.sampleRate = sampleRate
        envelopeGain = startsSilently ? .zero : 1
        volumeRequest = Atomic(initialVolumeRequest)
        activeVolumeRequest = initialVolumeRequest
        outputGain = clampedVolume
        outputGainTarget = clampedVolume
        darkFirstAlpha = Self.lowPassAlpha(cutoff: 180, sampleRate: sampleRate)
        darkSecondAlpha = Self.lowPassAlpha(cutoff: 65, sampleRate: sampleRate)
        grayLowAlpha = Self.lowPassAlpha(cutoff: 120, sampleRate: sampleRate)
        grayMidAlpha = Self.lowPassAlpha(cutoff: 2_000, sampleRate: sampleRate)
        deepLowAlpha = Self.lowPassAlpha(cutoff: 85, sampleRate: sampleRate)
        deepLowerAlpha = Self.lowPassAlpha(cutoff: 28, sampleRate: sampleRate)
        fanBodyAlpha = Self.lowPassAlpha(cutoff: 1_500, sampleRate: sampleRate)
        fanLowAlpha = Self.lowPassAlpha(cutoff: 100, sampleRate: sampleRate)
        cabinAirAlpha = Self.lowPassAlpha(cutoff: 900, sampleRate: sampleRate)
        cabinRumbleAlpha = Self.lowPassAlpha(cutoff: 75, sampleRate: sampleRate)
        oceanBodyAlpha = Self.lowPassAlpha(cutoff: 420, sampleRate: sampleRate)
        oceanLowerAlpha = Self.lowPassAlpha(cutoff: 95, sampleRate: sampleRate)
        envelopeGainStep = Float(1 / max(sampleRate * Self.envelopeDurationSeconds, 1))
    }

    /// Constructs the Core Audio callback outside the main-actor-isolated
    /// controller. AVAudioEngine invokes this closure on its real-time thread.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList -> OSStatus in
            render(frameCount: frameCount, into: audioBufferList)
            return noErr
        }
    }

    func render(frameCount: AVAudioFrameCount, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return }
        updateFadeOutState()
        updateVolumeRequest()

        for frame in 0..<Int(frameCount) {
            let sample = nextSample(checkForFadeOut: false)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }

    /// Requests a sample-ramped fade on the render thread. Atomics keep the
    /// UI thread from locking or mutating render-owned envelope state.
    func beginFadeOut() {
        fadeOutRequested.store(true, ordering: .releasing)
    }

    var hasFinishedFadeOut: Bool {
        fadeOutCompleted.load(ordering: .acquiring)
    }

    /// Requests an allocation-free, sample-accurate gain ramp on the render
    /// thread. The target and duration travel together in one atomic value.
    func setOutputVolume(_ volume: Float, durationSeconds: Double) {
        let clampedVolume = min(max(volume, 0), 1)
        let frames = UInt32(min(
            max((sampleRate * durationSeconds).rounded(), 0),
            Double(UInt32.max)
        ))
        volumeRequest.store(
            Self.packedVolumeRequest(volume: clampedVolume, rampFrames: frames),
            ordering: .releasing
        )
    }

    var currentOutputGain: Float { outputGain }

    func nextSample() -> Float {
        nextSample(checkForFadeOut: true)
    }

    private func nextSample(checkForFadeOut: Bool) -> Float {
        if checkForFadeOut {
            updateFadeOutState()
            updateVolumeRequest()
        }
        guard !isFadingOut || envelopeGain > 0 else { return 0 }

        let sample = generateSample()
        if isFadingOut {
            envelopeGain = max(envelopeGain - envelopeGainStep, 0)
            if envelopeGain == 0 {
                fadeOutCompleted.store(true, ordering: .releasing)
            }
        } else if envelopeGain < 1 {
            envelopeGain = min(envelopeGain + envelopeGainStep, 1)
        }
        advanceOutputGain()
        return sample * envelopeGain * outputGain
    }

    private func updateFadeOutState() {
        if !isFadingOut, fadeOutRequested.load(ordering: .acquiring) {
            isFadingOut = true
        }
    }

    private func updateVolumeRequest() {
        let request = volumeRequest.load(ordering: .acquiring)
        guard request != activeVolumeRequest else { return }
        activeVolumeRequest = request

        outputGainTarget = Float(bitPattern: UInt32(request >> 32))
        outputGainFramesRemaining = Int(UInt32(truncatingIfNeeded: request))
        guard outputGainFramesRemaining > 0 else {
            outputGain = outputGainTarget
            outputGainStep = 0
            return
        }
        outputGainStep = (outputGainTarget - outputGain) / Float(outputGainFramesRemaining)
    }

    private func advanceOutputGain() {
        guard outputGainFramesRemaining > 0 else { return }
        outputGain += outputGainStep
        outputGainFramesRemaining -= 1
        if outputGainFramesRemaining == 0 {
            outputGain = outputGainTarget
        }
    }

    private static func packedVolumeRequest(volume: Float, rampFrames: UInt32) -> UInt64 {
        UInt64(volume.bitPattern) << 32 | UInt64(rampFrames)
    }

    private func generateSample() -> Float {
        let white = nextWhite()
        switch kind {
        case .white:
            return white * 0.22
        case .pink:
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            return (pink0 + pink1 + pink2 + white * 0.1848) * 0.055
        case .brown:
            brown = (brown + white * 0.018).clamped(to: -1...1)
            brown *= 0.9985
            return brown * 0.48
        case .dark:
            // Two low-pass stages make a soft, very bass-heavy "dark" noise.
            // Coefficients are derived from cutoff frequencies so the sound stays
            // consistent when the output device's sample rate changes.
            darkLow += darkFirstAlpha * (white - darkLow)
            darkLower += darkSecondAlpha * (darkLow - darkLower)
            return (darkLow * 0.30 + darkLower * 1.8).softLimited(to: 0.65)
        case .gray:
            grayLow += grayLowAlpha * (white - grayLow)
            grayMid += grayMidAlpha * (white - grayMid)
            let high = white - grayMid
            return (white * 0.08 + grayLow * 0.60 + high * 0.20).softLimited(to: 0.65)
        case .blue:
            let sample = (white - previousWhite) * 0.18
            previousWhite = white
            return sample.clamped(to: -0.65...0.65)
        case .violet:
            let sample = (white - 2 * previousWhite + secondPreviousWhite) * 0.10
            secondPreviousWhite = previousWhite
            previousWhite = white
            return sample.clamped(to: -0.65...0.65)
        case .deep:
            deepLow += deepLowAlpha * (white - deepLow)
            deepLower += deepLowerAlpha * (deepLow - deepLower)
            return (deepLow * 0.18 + deepLower * 2.2).softLimited(to: 0.62)
        case .fan:
            fanBody += fanBodyAlpha * (white - fanBody)
            fanLow += fanLowAlpha * (fanBody - fanLow)
            let hum = nextTone(frequency: 58) * 0.035 + Float(sin(tonePhase * 2)) * 0.012
            return ((fanBody - fanLow) * 0.34 + fanLow * 0.12 + hum).softLimited(to: 0.65)
        case .cabin:
            cabinAir += cabinAirAlpha * (white - cabinAir)
            cabinRumble += cabinRumbleAlpha * (cabinAir - cabinRumble)
            let drone = nextTone(frequency: 43) * 0.045
            return (cabinAir * 0.18 + cabinRumble * 0.75 + drone).softLimited(to: 0.65)
        case .ocean:
            oceanBody += oceanBodyAlpha * (white - oceanBody)
            oceanLower += oceanLowerAlpha * (oceanBody - oceanLower)
            swellPhase += 2 * Double.pi * 0.075 / sampleRate
            if swellPhase >= 2 * Double.pi { swellPhase -= 2 * Double.pi }
            let swell = Float(0.32 + 0.68 * ((sin(swellPhase) + 1) * 0.5))
            return ((oceanBody * 0.35 + oceanLower * 1.1) * swell).softLimited(to: 0.65)
        }
    }

    private func nextTone(frequency: Double) -> Float {
        tonePhase += 2 * Double.pi * frequency / sampleRate
        if tonePhase >= 2 * Double.pi { tonePhase -= 2 * Double.pi }
        return Float(sin(tonePhase))
    }

    private func nextWhite() -> Float {
        randomState ^= randomState >> 12
        randomState ^= randomState << 25
        randomState ^= randomState >> 27
        let value = randomState &* 2_685_821_657_736_338_717
        let normalized = Float(value >> 40) / Float(0x00ff_ffff)
        return normalized * 2 - 1
    }

    private static func lowPassAlpha(cutoff: Double, sampleRate: Double) -> Float {
        Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }

    /// Preserves small signals while rounding off peaks instead of introducing
    /// a hard corner that can sound like a faint click.
    func softLimited(to limit: Float, kneeRatio: Float = 0.8) -> Float {
        let magnitude = abs(self)
        let knee = limit * kneeRatio
        guard magnitude > knee else { return self }
        let headroom = limit - knee
        let excess = magnitude - knee
        let softened = knee + excess / (1 + excess / headroom)
        return self.sign == .minus ? -softened : softened
    }
}
