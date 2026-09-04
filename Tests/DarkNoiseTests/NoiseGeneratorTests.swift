import AVFoundation
import Foundation
import Testing
@testable import Nullwave

struct NoiseGeneratorTests {
    @Test func everyNoiseTypeProducesFiniteBoundedSamples() {
        for kind in NoiseKind.allCases {
            let generator = NoiseGenerator(kind: kind, sampleRate: 48_000)
            var hasNonZeroSample = false
            for _ in 0..<100_000 {
                let sample = generator.nextSample()
                #expect(sample.isFinite)
                #expect(abs(sample) <= 1)
                hasNonZeroSample = hasNonZeroSample || sample != 0
            }
            #expect(hasNonZeroSample)
        }
    }

    @Test func startupIsRampedInRatherThanBeginningWithAnAbruptSample() {
        for kind in NoiseKind.allCases {
            let generator = NoiseGenerator(kind: kind, sampleRate: 48_000)
            #expect(abs(generator.nextSample()) < 0.001)
        }
    }

    @Test func fadeOutReachesSilenceBeforeTheGeneratorStops() {
        let sampleRate = 48_000.0
        let generator = NoiseGenerator(kind: .white, sampleRate: sampleRate)
        let envelopeFrames = Int(sampleRate * NoiseGenerator.envelopeDurationSeconds)

        for _ in 0..<envelopeFrames { _ = generator.nextSample() }
        generator.beginFadeOut()
        #expect(!generator.hasFinishedFadeOut)

        for _ in 0..<envelopeFrames { _ = generator.nextSample() }

        #expect(generator.hasFinishedFadeOut)
        #expect(generator.nextSample() == 0)
    }

    @Test func continuousSoundsAvoidIsolatedLargeSampleSteps() {
        let continuousKinds: [NoiseKind] = [.dark, .brown, .deep, .fan, .cabin, .ocean]

        for kind in continuousKinds {
            let generator = NoiseGenerator(kind: kind, sampleRate: 48_000)
            var previous = generator.nextSample()
            var largestStep = Float.zero

            for _ in 0..<250_000 {
                let sample = generator.nextSample()
                largestStep = max(largestStep, abs(sample - previous))
                previous = sample
            }

            #expect(largestStep < 0.18, "\(kind.displayName) produced an abrupt sample step of \(largestStep)")
        }
    }
}

@MainActor
struct NoiseAudioControllerTests {
    @Test func soundAndVolumePersistAcrossRestarts() {
        let suiteName = "NullwaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = NoiseAudioController(defaults: defaults)
        #expect(firstLaunch.kind == .dark)
        #expect(firstLaunch.volume == 0.30)

        firstLaunch.kind = .pink
        firstLaunch.volume = 0.67
        firstLaunch.kind = .dark
        firstLaunch.volume = 0.31
        firstLaunch.kind = .pink

        let nextLaunch = NoiseAudioController(defaults: defaults)
        #expect(nextLaunch.kind == .pink)
        #expect(nextLaunch.volume == 0.67)
        #expect(!nextLaunch.isPlaying)

        nextLaunch.kind = .dark
        #expect(nextLaunch.volume == 0.31)
    }

    @Test func favoritesPersistAndRemainUnique() {
        let suiteName = "NullwaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = NoiseAudioController(defaults: defaults)
        #expect(controller.favoriteKinds == [.dark, .brown, .pink])

        controller.setFavorite(at: 1, to: .ocean)
        controller.moveFavorite(.ocean, before: .dark)

        let nextLaunch = NoiseAudioController(defaults: defaults)
        #expect(nextLaunch.favoriteKinds == [.ocean, .dark, .pink])

        nextLaunch.setFavorite(at: 0, to: .pink)
        #expect(nextLaunch.favoriteKinds == [.pink, .dark, .ocean])

        nextLaunch.removeFavorite(.dark)
        nextLaunch.removeFavorite(.ocean)
        nextLaunch.removeFavorite(.pink)
        #expect(nextLaunch.favoriteKinds == [.pink])

        let finalLaunch = NoiseAudioController(defaults: defaults)
        #expect(finalLaunch.favoriteKinds == [.pink])

        finalLaunch.setFavorite(at: 1, to: .deep)
        #expect(finalLaunch.favoriteKinds == [.pink, .deep])
    }
}

@MainActor
struct CallActivityControllerTests {
    @Test func pausesAfterSustainedInputAndResumesAfterItEnds() {
        let suiteName = "NullwaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playback = FakePlayback(isPlaying: true)
        let controller = CallActivityController(audio: playback, defaults: defaults)
        let start = Date()

        controller.update(rawCallActive: true, now: start)
        controller.update(rawCallActive: true, now: start.addingTimeInterval(0.9))
        #expect(!playback.isPlaying)
        #expect(controller.isPausedForCall)
        #expect(playback.stopCount == 1)

        controller.update(rawCallActive: false, now: start.addingTimeInterval(1.0))
        controller.update(rawCallActive: false, now: start.addingTimeInterval(2.3))
        #expect(playback.isPlaying)
        #expect(!controller.isPausedForCall)
        #expect(playback.startCount == 1)
    }

    @Test func doesNotResumeSoundThatWasAlreadyStopped() {
        let suiteName = "NullwaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playback = FakePlayback(isPlaying: false)
        let controller = CallActivityController(audio: playback, defaults: defaults)
        let start = Date()

        controller.update(rawCallActive: true, now: start)
        controller.update(rawCallActive: true, now: start.addingTimeInterval(0.9))
        controller.update(rawCallActive: false, now: start.addingTimeInterval(1.0))
        controller.update(rawCallActive: false, now: start.addingTimeInterval(2.3))

        #expect(!playback.isPlaying)
        #expect(playback.startCount == 0)
        #expect(playback.stopCount == 0)
    }

    @Test func recognizesOnlyASharedInputOutputRoute() {
        #expect(CallActivityController.isCallRoute(
            inputDeviceID: 42,
            outputDeviceID: 42
        ))
        #expect(!CallActivityController.isCallRoute(
            inputDeviceID: 41,
            outputDeviceID: 42
        ))
    }
}

@MainActor
private final class FakePlayback: NoisePlaybackControlling {
    var isPlaying: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    func start() {
        isPlaying = true
        startCount += 1
    }

    func stop() {
        isPlaying = false
        stopCount += 1
    }
}
