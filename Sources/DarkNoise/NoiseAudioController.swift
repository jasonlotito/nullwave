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
            if isPlaying {
                engine.mainMixerNode.outputVolume = Float(clamped)
            }
            defaults.set(clamped, forKey: volumeKey(for: kind))
        }
    }

    @Published var kind: NoiseKind {
        didSet {
            if !isChangingPreviewSound {
                defaults.set(kind.rawValue, forKey: Keys.kind)
            }
            guard oldValue != kind else { return }
            volume = storedVolume(for: kind)
            if playbackIsRequested { restart() }
        }
    }

    @Published private(set) var favoriteKinds: [NoiseKind]

    private enum Keys {
        static let legacyVolume = "noiseVolume"
        static let kind = "noiseKind"
        static let favorites = "favoriteNoiseKinds"
        static let volumePrefix = "noiseVolume."
    }

    private let defaults: UserDefaults
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var generator: NoiseGenerator?
    private var fadeOutTask: Task<Void, Never>?
    private var shouldStartAfterFade = false
    private var shouldDeactivateAfterFade = true
    private var previewOrigin: (kind: NoiseKind, wasPlaying: Bool)?
    private var isChangingPreviewSound = false
#if os(iOS)
    private var shouldResumeAfterInterruption = false
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedKind = NoiseKind(rawValue: defaults.string(forKey: Keys.kind) ?? "") ?? .dark
        kind = savedKind
        volume = Self.readVolume(for: savedKind, defaults: defaults, useLegacyValue: true)
        favoriteKinds = Self.readFavorites(defaults: defaults)
        if defaults.object(forKey: Self.volumeKey(for: savedKind)) == nil {
            defaults.set(volume, forKey: Self.volumeKey(for: savedKind))
        }
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

    func start() {
        guard !isPlaying else { return }
        if fadeOutTask != nil {
            shouldStartAfterFade = true
            shouldDeactivateAfterFade = false
            return
        }

        do {
#if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // Playback sessions support AirPlay implicitly. `allowAirPlay` may
            // only be set explicitly with `playAndRecord` and returns paramErr
            // (-50) on physical devices when combined with `playback`.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
#endif
            try configureAndStartEngine()
            isPlaying = true
            playbackErrorMessage = nil
        } catch {
#if canImport(AppKit)
            NSSound.beep()
#endif
            isPlaying = false
            playbackErrorMessage = error.localizedDescription
            NSLog("Nullwave could not start audio: %@", error.localizedDescription)
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
        guard isPlaying, engine.isRunning, let generator else {
            stopImmediately(deactivateAudioSession: shouldDeactivateAfterFade)
            if startAfterFade { start() }
            return
        }

        isPlaying = false
        generator.beginFadeOut()
        fadeOutTask = Task { [weak self] in
            // The request may arrive just after an audio buffer began. Wait
            // for the render thread to confirm silence instead of assuming a
            // wall-clock delay means the envelope has completed.
            for _ in 0..<50 where !generator.hasFinishedFadeOut {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
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
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        generator = nil
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

    private func restart() {
        beginFadeOut(deactivateAudioSession: false, startAfterFade: true)
    }

    private func storedVolume(for kind: NoiseKind) -> Double {
        Self.readVolume(for: kind, defaults: defaults, useLegacyValue: false)
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

    private func volumeKey(for kind: NoiseKind) -> String {
        Self.volumeKey(for: kind)
    }

    private func configureAndStartEngine() throws {
        let output = engine.outputNode
        let outputFormat = output.inputFormat(forBus: 0)
        let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: max(outputFormat.channelCount, 1)
        )!

        let generator = NoiseGenerator(kind: kind, sampleRate: outputFormat.sampleRate)
        let source = generator.makeSourceNode(format: renderFormat)

        self.generator = generator
        self.sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.outputVolume = Float(volume)
        engine.prepare()
        try engine.start()
    }
}

extension NoiseAudioController: NoisePlaybackControlling {}
