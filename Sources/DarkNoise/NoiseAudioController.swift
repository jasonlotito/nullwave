import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
import Combine
import Foundation

@MainActor
protocol NoisePlaybackControlling: AnyObject {
    var isPlaying: Bool { get }
    func start()
    func stop()
}

enum NoiseKind: String, CaseIterable, Identifiable, Sendable {
    case dark, brown, pink, white
    case gray, blue, violet, deep, fan, cabin, ocean

    var id: Self { self }
    var displayName: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .dark: "moon.fill"
        case .brown: "mountain.2.fill"
        case .pink: "heart.fill"
        case .white: "sparkles"
        case .gray: "circle.lefthalf.filled"
        case .blue: "wind"
        case .violet: "waveform.path"
        case .deep: "arrow.down.to.line.compact"
        case .fan: "fan.fill"
        case .cabin: "airplane"
        case .ocean: "water.waves"
        }
    }

    var summary: String {
        switch self {
        case .dark: "Very soft, bass-heavy noise with most high frequencies removed."
        case .brown: "A warm, low-frequency rumble that falls by about 6 dB per octave."
        case .pink: "Balanced natural-sounding noise with less treble than white noise."
        case .white: "Equal energy at every frequency, producing a bright broadband hiss."
        case .gray: "Shaped around human hearing for a more even perceived loudness."
        case .blue: "Bright noise whose energy increases toward higher frequencies."
        case .violet: "An intense, very high-frequency noise with minimal low end."
        case .deep: "An extra-low, gently filtered rumble beneath the Dark profile."
        case .fan: "Steady filtered airflow with a subtle mechanical hum."
        case .cabin: "Broad airflow layered over the low drone of an aircraft cabin."
        case .ocean: "Low, filtered noise that slowly swells and recedes like surf."
        }
    }

    var bestFor: String {
        switch self {
        case .dark: "Sleep, winding down, and masking sound without much hiss."
        case .brown: "Relaxation, focus, and softening low or mid-frequency distractions."
        case .pink: "Sleep and general-purpose background sound with a natural character."
        case .white: "Masking voices and sharper environmental sounds."
        case .gray: "Broadband masking when you want frequencies to feel more even."
        case .blue: "A crisp backdrop or masking higher-pitched sounds at low volume."
        case .violet: "Specialized high-frequency masking; start at a low volume."
        case .deep: "A subdued nighttime sound with very little upper-frequency energy."
        case .fan: "Work, sleep, and anyone who prefers a familiar steady appliance sound."
        case .cabin: "Concentration, travel ambience, and a fuller continuous background."
        case .ocean: "Relaxation and sleep when a gently changing sound feels more natural."
        }
    }

    var spectrum: String {
        switch self {
        case .dark: "Low-pass · bass dominant"
        case .brown: "−6 dB/octave"
        case .pink: "−3 dB/octave"
        case .white: "Flat spectrum"
        case .gray: "Perceptually weighted"
        case .blue: "+3 dB/octave"
        case .violet: "+6 dB/octave"
        case .deep: "Very-low-pass"
        case .fan: "Filtered airflow + hum"
        case .cabin: "Low drone + airflow"
        case .ocean: "Slowly modulated low-pass"
        }
    }
}

@MainActor
final class NoiseAudioController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var previewKind: NoiseKind?
    @Published private(set) var playbackErrorMessage: String?

    @Published var volume: Double {
        didSet {
            let clamped = min(max(volume, 0), 1)
            if volume != clamped { volume = clamped }
            updateRenderedVolume(forChangedSecondaryVolume: false)
            defaults.set(clamped, forKey: volumeKey(for: kind))
        }
    }

    @Published var otherAudioVolume: Double {
        didSet {
            let clamped = min(max(otherAudioVolume, 0), 1)
            if otherAudioVolume != clamped { otherAudioVolume = clamped }
            updateRenderedVolume(forChangedSecondaryVolume: true)
            defaults.set(clamped, forKey: otherAudioVolumeKey(for: kind))
        }
    }

    @Published var isOtherAudioDuckingEnabled: Bool {
        didSet {
            defaults.set(isOtherAudioDuckingEnabled, forKey: Keys.duckingEnabled)
            setPlaybackVolume(
                effectiveVolume,
                duration: isOtherAudioDuckingEnabled && isOtherAudioPlaying
                    ? VolumeRamp.duckAttack
                    : VolumeRamp.duckRelease
            )
        }
    }

    @Published private(set) var isOtherAudioPlaying = false

    @Published var kind: NoiseKind {
        didSet {
            if !isChangingPreviewSound {
                defaults.set(kind.rawValue, forKey: Keys.kind)
            }
            guard oldValue != kind else { return }
            volume = storedVolume(for: kind)
            otherAudioVolume = storedOtherAudioVolume(for: kind)
            if playbackIsRequested { restart() }
        }
    }

    @Published private(set) var favoriteKinds: [NoiseKind]

    private enum Keys {
        static let legacyVolume = "noiseVolume"
        static let kind = "noiseKind"
        static let favorites = "favoriteNoiseKinds"
        static let volumePrefix = "noiseVolume."
        static let otherAudioVolumePrefix = "otherAudioVolume."
        static let duckingEnabled = "lowerVolumeWhileOtherAudioPlays"
    }

    private enum VolumeRamp {
        static let directAdjustment = 0.02
        static let duckAttack = 0.20
        static let duckRelease = 0.40
    }

    private let defaults: UserDefaults
#if os(iOS)
    private var player: AVAudioPlayer?
#else
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var generator: NoiseGenerator?
#endif
    private var fadeOutTask: Task<Void, Never>?
    private var shouldStartAfterFade = false
    private var shouldDeactivateAfterFade = true
    private var previewOrigin: (kind: NoiseKind, wasPlaying: Bool)?
    private var isChangingPreviewSound = false
#if os(iOS)
    private var shouldResumeAfterInterruption = false
    private var otherAudioTimer: Timer?
    private static var cachedNoiseLoops: [NoiseKind: (sampleRate: UInt32, data: Data)] = [:]
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedKind = NoiseKind(rawValue: defaults.string(forKey: Keys.kind) ?? "") ?? .dark
        let savedVolume = Self.readVolume(
            for: savedKind,
            defaults: defaults,
            useLegacyValue: true
        )
        kind = savedKind
        volume = savedVolume
        otherAudioVolume = Self.readOtherAudioVolume(
            for: savedKind,
            defaults: defaults,
            fallback: savedVolume
        )
#if os(iOS)
        isOtherAudioDuckingEnabled = true
#else
        isOtherAudioDuckingEnabled = defaults.bool(forKey: Keys.duckingEnabled)
#endif
        favoriteKinds = Self.readFavorites(defaults: defaults)
        if defaults.object(forKey: Self.volumeKey(for: savedKind)) == nil {
            defaults.set(volume, forKey: Self.volumeKey(for: savedKind))
        }
        if defaults.object(forKey: Self.otherAudioVolumeKey(for: savedKind)) == nil {
            defaults.set(otherAudioVolume, forKey: Self.otherAudioVolumeKey(for: savedKind))
        }
#if os(iOS)
        try? configureIOSAudioSessionCategory()
        startMonitoringOtherAudio()
#endif
    }

    private var playbackIsRequested: Bool {
        isPlaying || shouldStartAfterFade
    }

    func setFavorite(at index: Int, to newKind: NoiseKind) {
        if index == favoriteKinds.count, favoriteKinds.count < 3 {
            guard !favoriteKinds.contains(newKind) else { return }
            favoriteKinds.append(newKind)
            saveFavorites()
            return
        }
        guard favoriteKinds.indices.contains(index) else { return }
        if let existingIndex = favoriteKinds.firstIndex(of: newKind) {
            favoriteKinds.swapAt(index, existingIndex)
        } else {
            favoriteKinds[index] = newKind
        }
        saveFavorites()
    }

    func removeFavorite(_ kind: NoiseKind) {
        guard favoriteKinds.count > 1,
              let index = favoriteKinds.firstIndex(of: kind) else { return }
        favoriteKinds.remove(at: index)
        saveFavorites()
    }

    func moveFavorite(_ source: NoiseKind, before destination: NoiseKind) {
        guard source != destination,
              let sourceIndex = favoriteKinds.firstIndex(of: source),
              let destinationIndex = favoriteKinds.firstIndex(of: destination) else { return }
        let moved = favoriteKinds.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        favoriteKinds.insert(moved, at: insertionIndex)
        saveFavorites()
    }

    func toggle() {
        isPlaying ? stop() : start()
    }

    func togglePreview(of kind: NoiseKind) {
        if previewKind == kind {
            stopPreview()
            return
        }
        stopPreview()
        previewOrigin = (self.kind, playbackIsRequested)
        stop()
        isChangingPreviewSound = true
        self.kind = kind
        isChangingPreviewSound = false
        previewKind = kind
        start()
    }

    func stopPreview() {
        guard let origin = previewOrigin else { return }
        stop()
        isChangingPreviewSound = true
        kind = origin.kind
        isChangingPreviewSound = false
        previewKind = nil
        previewOrigin = nil
        if origin.wasPlaying { start() }
    }

    func savedVolume(for kind: NoiseKind) -> Double {
        kind == self.kind ? volume : storedVolume(for: kind)
    }

    func setSavedVolume(_ newVolume: Double, for kind: NoiseKind) {
        let clamped = min(max(newVolume, 0), 1)
        if kind == self.kind {
            volume = clamped
        } else {
            objectWillChange.send()
            defaults.set(clamped, forKey: volumeKey(for: kind))
        }
    }

    func savedOtherAudioVolume(for kind: NoiseKind) -> Double {
        kind == self.kind ? otherAudioVolume : storedOtherAudioVolume(for: kind)
    }

    func setSavedOtherAudioVolume(_ newVolume: Double, for kind: NoiseKind) {
        let clamped = min(max(newVolume, 0), 1)
        if kind == self.kind {
            otherAudioVolume = clamped
        } else {
            objectWillChange.send()
            defaults.set(clamped, forKey: otherAudioVolumeKey(for: kind))
        }
    }

    func updateOtherAudioPlaying(_ otherAudioIsPlaying: Bool) {
        guard isOtherAudioPlaying != otherAudioIsPlaying else { return }
        isOtherAudioPlaying = otherAudioIsPlaying
        guard isOtherAudioDuckingEnabled else { return }
        setPlaybackVolume(
            effectiveVolume,
            duration: otherAudioIsPlaying
                ? VolumeRamp.duckAttack
                : VolumeRamp.duckRelease
        )
    }

    func start() {
        guard !isPlaying else { return }
        if fadeOutTask != nil {
            shouldStartAfterFade = true
            shouldDeactivateAfterFade = false
            return
        }

        do {
#if os(iOS)
            try configureIOSAudioSessionCategory()
            refreshOtherAudioState()
            let preparedPlayer = try makeIOSPlayer()

            try startIOSPlayer(preparedPlayer)
#else
            try configureAndStartEngine()
#endif
            isPlaying = true
            playbackErrorMessage = nil
        } catch {
            logPlaybackStartFailure(error)
            discardFailedPlaybackStart()
#if canImport(AppKit)
            NSSound.beep()
#endif
            isPlaying = false
            playbackErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        beginFadeOut(deactivateAudioSession: true, startAfterFade: false)
    }

    /// Used when the process or output route is going away and no audible
    /// fade can reliably finish.
    func shutdown() {
        stopImmediately(deactivateAudioSession: true)
    }

#if os(iOS)
    /// Configure the category early, while leaving activation deferred until
    /// the user starts playback.
    private func configureIOSAudioSessionCategory() throws {
        // Playback sessions support AirPlay implicitly. `allowAirPlay` may
        // only be set explicitly with `playAndRecord` and returns paramErr
        // (-50) on physical devices when combined with `playback`.
        // Long-form route sharing also cannot be combined with mixWithOthers.
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
    }

    private func startMonitoringOtherAudio() {
        refreshOtherAudioState()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOtherAudioState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        otherAudioTimer = timer
    }

    func refreshOtherAudioState() {
        updateOtherAudioPlaying(AVAudioSession.sharedInstance().isOtherAudioPlaying)
    }

    func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = playbackIsRequested
            stopImmediately(deactivateAudioSession: false)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = shouldResumeAfterInterruption && options.contains(.shouldResume)
            shouldResumeAfterInterruption = false
            if shouldResume { start() }
        @unknown default:
            break
        }
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else {
            return
        }
        stopImmediately(deactivateAudioSession: true)
    }
#endif

    private func beginFadeOut(deactivateAudioSession: Bool, startAfterFade: Bool) {
        shouldStartAfterFade = startAfterFade
        shouldDeactivateAfterFade = deactivateAudioSession && !startAfterFade

        if fadeOutTask != nil { return }
#if os(iOS)
        guard isPlaying, let player, player.isPlaying else {
            stopImmediately(deactivateAudioSession: shouldDeactivateAfterFade)
            if startAfterFade { start() }
            return
        }
#else
        guard isPlaying, engine.isRunning, let generator else {
            stopImmediately(deactivateAudioSession: shouldDeactivateAfterFade)
            if startAfterFade { start() }
            return
        }
#endif

        isPlaying = false
#if os(iOS)
        player.setVolume(0, fadeDuration: NoiseGenerator.envelopeDurationSeconds)
#else
        generator.beginFadeOut()
#endif
        fadeOutTask = Task { [weak self] in
#if os(iOS)
            try? await Task.sleep(
                nanoseconds: UInt64(NoiseGenerator.envelopeDurationSeconds * 1_000_000_000)
            )
#else
            // The request may arrive just after an audio buffer began. Wait
            // for the render thread to confirm silence instead of assuming a
            // wall-clock delay means the envelope has completed.
            for _ in 0..<50 where !generator.hasFinishedFadeOut {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
#endif
            guard let self, !Task.isCancelled else { return }

            let restart = self.shouldStartAfterFade
            let deactivate = self.shouldDeactivateAfterFade && !restart
            self.fadeOutTask = nil
            self.stopImmediately(deactivateAudioSession: deactivate)
            if restart { self.start() }
        }
    }

    private func stopImmediately(deactivateAudioSession: Bool) {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        shouldStartAfterFade = false
        shouldDeactivateAfterFade = true
#if os(iOS)
        player?.stop()
        player = nil
#else
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        generator = nil
#endif
        isPlaying = false
#if os(iOS)
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
#endif
    }

    private func discardFailedPlaybackStart() {
#if os(iOS)
        player?.stop()
        player = nil
#else
        engine.stop()
        if let sourceNode, engine.attachedNodes.contains(sourceNode) {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        generator = nil
        engine.reset()
#endif
    }

    private func logPlaybackStartFailure(_ error: Error) {
        let nsError = error as NSError
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        NSLog(
            "Nullwave could not start audio: %@ (domain=%@ code=%ld, category=%@, route=%@, sampleRate=%.0f, otherAudio=%@)",
            error.localizedDescription,
            nsError.domain,
            nsError.code,
            session.category.rawValue,
            route.isEmpty ? "none" : route,
            session.sampleRate,
            session.isOtherAudioPlaying ? "yes" : "no"
        )
#else
        NSLog(
            "Nullwave could not start audio: %@ (domain=%@ code=%ld)",
            error.localizedDescription,
            nsError.domain,
            nsError.code
        )
#endif
    }

    private func restart() {
        beginFadeOut(deactivateAudioSession: false, startAfterFade: true)
    }

    private func storedVolume(for kind: NoiseKind) -> Double {
        Self.readVolume(for: kind, defaults: defaults, useLegacyValue: false)
    }

    private func storedOtherAudioVolume(for kind: NoiseKind) -> Double {
        Self.readOtherAudioVolume(
            for: kind,
            defaults: defaults,
            fallback: storedVolume(for: kind)
        )
    }

    private static func readVolume(
        for kind: NoiseKind,
        defaults: UserDefaults,
        useLegacyValue: Bool
    ) -> Double {
        let key = volumeKey(for: kind)
        if defaults.object(forKey: key) != nil {
            return min(max(defaults.double(forKey: key), 0), 1)
        }
        if useLegacyValue, defaults.object(forKey: Keys.legacyVolume) != nil {
            return min(max(defaults.double(forKey: Keys.legacyVolume), 0), 1)
        }
        return 0.30
    }

    private static func readOtherAudioVolume(
        for kind: NoiseKind,
        defaults: UserDefaults,
        fallback: Double
    ) -> Double {
        let key = otherAudioVolumeKey(for: kind)
        if defaults.object(forKey: key) != nil {
            return min(max(defaults.double(forKey: key), 0), 1)
        }
        // Preserve an existing user's current loudness until they choose a
        // separate ducked volume. New installs still begin at 30% / 30%.
        return fallback
    }

    private static func readFavorites(defaults: UserDefaults) -> [NoiseKind] {
        guard let savedValues = defaults.stringArray(forKey: Keys.favorites) else {
            return [.dark, .brown, .pink]
        }
        let saved = savedValues.compactMap(NoiseKind.init(rawValue:))
        var unique = saved.reduce(into: [NoiseKind]()) { result, kind in
            if !result.contains(kind) { result.append(kind) }
        }
        if unique.isEmpty {
            unique = [.dark]
        }
        return Array(unique.prefix(3))
    }

    private func saveFavorites() {
        defaults.set(favoriteKinds.map(\.rawValue), forKey: Keys.favorites)
    }

    private static func volumeKey(for kind: NoiseKind) -> String {
        Keys.volumePrefix + kind.rawValue
    }

    private static func otherAudioVolumeKey(for kind: NoiseKind) -> String {
        Keys.otherAudioVolumePrefix + kind.rawValue
    }

    private func volumeKey(for kind: NoiseKind) -> String {
        Self.volumeKey(for: kind)
    }

    private func otherAudioVolumeKey(for kind: NoiseKind) -> String {
        Self.otherAudioVolumeKey(for: kind)
    }

    private var effectiveVolume: Double {
        isOtherAudioDuckingEnabled && isOtherAudioPlaying ? otherAudioVolume : volume
    }

    private func updateRenderedVolume(forChangedSecondaryVolume: Bool) {
        let secondaryVolumeIsActive = isOtherAudioDuckingEnabled && isOtherAudioPlaying
        guard secondaryVolumeIsActive == forChangedSecondaryVolume else { return }
        setPlaybackVolume(effectiveVolume, duration: VolumeRamp.directAdjustment)
    }

    private func setPlaybackVolume(_ volume: Double, duration: Double) {
#if os(iOS)
        player?.setVolume(Float(volume), fadeDuration: duration)
#else
        generator?.setOutputVolume(Float(volume), durationSeconds: duration)
#endif
    }

#if os(iOS)
    private func makeIOSPlayer() throws -> AVAudioPlayer {
        // Keep the sound synthesized locally, then use iOS's system-managed
        // player for stable looping and smooth volume fades.
        let sampleRate = max(AVAudioSession.sharedInstance().sampleRate, 44_100)
        let roundedSampleRate = UInt32(sampleRate.rounded())
        let data: Data
        if let cached = Self.cachedNoiseLoops[kind], cached.sampleRate == roundedSampleRate {
            data = cached.data
        } else {
            data = Self.makeLoopingNoiseWAV(kind: kind, sampleRate: sampleRate)
            Self.cachedNoiseLoops[kind] = (roundedSampleRate, data)
        }
        return try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
    }

    private func startIOSPlayer(_ player: AVAudioPlayer) throws {
        player.numberOfLoops = -1
        player.volume = 0
        guard player.prepareToPlay() else {
            throw NSError(
                domain: "com.jasonlotito.nullwave.audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The system audio player could not prepare."]
            )
        }
        guard player.play() else {
            throw NSError(
                domain: "com.jasonlotito.nullwave.audio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The system audio player could not start."]
            )
        }
        self.player = player
        player.setVolume(
            Float(effectiveVolume),
            fadeDuration: NoiseGenerator.envelopeDurationSeconds
        )
    }
#else
    private func configureAndStartEngine() throws {
        let output = engine.outputNode
        let outputFormat = output.inputFormat(forBus: 0)
        let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: max(outputFormat.channelCount, 1)
        )!

        let generator = NoiseGenerator(
            kind: kind,
            sampleRate: outputFormat.sampleRate,
            initialVolume: Float(effectiveVolume)
        )
        let source = generator.makeSourceNode(format: renderFormat)

        self.generator = generator
        self.sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()
    }
#endif

#if os(iOS)
    /// Builds a mono 16-bit PCM WAV entirely in memory. The beginning is a
    /// crossfade from the generator's continuation back into its first
    /// samples. That makes both sides of the repeating boundary continuous,
    /// without a periodic drop in volume or a click.
    private static func makeLoopingNoiseWAV(kind: NoiseKind, sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate.rounded())
        let frameCount = Int(rate) * 30
        let bytesPerSample = 2
        let headerSize = 44
        let payloadSize = frameCount * bytesPerSample
        let crossfadeFrames = max(Int(sampleRate * NoiseGenerator.envelopeDurationSeconds), 2)
        let generator = NoiseGenerator(
            kind: kind,
            sampleRate: sampleRate,
            initialVolume: 1,
            startsSilently: false
        )
        var samples = [Float]()
        samples.reserveCapacity(frameCount + crossfadeFrames)
        for _ in 0..<(frameCount + crossfadeFrames) {
            samples.append(generator.nextSample())
        }
        var data = Data(count: headerSize + payloadSize)

        data.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)

            func writeASCII(_ string: String, at offset: Int) {
                for (index, byte) in string.utf8.enumerated() {
                    bytes[offset + index] = byte
                }
            }

            func writeUInt16(_ value: UInt16, at offset: Int) {
                bytes[offset] = UInt8(truncatingIfNeeded: value)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }

            func writeUInt32(_ value: UInt32, at offset: Int) {
                bytes[offset] = UInt8(truncatingIfNeeded: value)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
                bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
            }

            writeASCII("RIFF", at: 0)
            writeUInt32(UInt32(36 + payloadSize), at: 4)
            writeASCII("WAVE", at: 8)
            writeASCII("fmt ", at: 12)
            writeUInt32(16, at: 16)
            writeUInt16(1, at: 20)
            writeUInt16(1, at: 22)
            writeUInt32(rate, at: 24)
            writeUInt32(rate * UInt32(bytesPerSample), at: 28)
            writeUInt16(UInt16(bytesPerSample), at: 32)
            writeUInt16(16, at: 34)
            writeASCII("data", at: 36)
            writeUInt32(UInt32(payloadSize), at: 40)

            for frame in 0..<frameCount {
                let sample: Float
                if frame < crossfadeFrames {
                    let mix = Float(frame) / Float(crossfadeFrames - 1)
                    sample = samples[frameCount + frame] * (1 - mix) + samples[frame] * mix
                } else {
                    sample = samples[frame]
                }

                let clampedSample = min(max(sample, -1), 1)
                let integer = Int16((clampedSample * Float(Int16.max)).rounded())
                writeUInt16(
                    UInt16(bitPattern: integer),
                    at: headerSize + frame * bytesPerSample
                )
            }
        }

        return data
    }

#endif
}

extension NoiseAudioController: NoisePlaybackControlling {}
