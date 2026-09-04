import AppKit
import CoreAudio
import Combine
import Foundation

/// Watches the system audio route and treats one device becoming both the
/// default input and output as headset call mode.
@MainActor
final class CallActivityController: ObservableObject {
    @Published private(set) var isCallActive = false
    @Published private(set) var isPausedForCall = false

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                applyCallState()
            } else {
                resumeIfNeeded()
            }
        }
    }

    var shouldResumePlaybackAfterRelaunch: Bool {
        audio.isPlaying || isPausedForCall
    }

    private enum Keys {
        static let enabled = "pauseDuringCalls"
    }

    private let audio: any NoisePlaybackControlling
    private let defaults: UserDefaults
    private var timer: Timer?
    private var candidateState = false
    private var candidateSince = Date()
    private var shouldResumeAfterCall = false

    init(audio: any NoisePlaybackControlling, defaults: UserDefaults = .standard) {
        self.audio = audio
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) == nil
            ? true
            : defaults.bool(forKey: Keys.enabled)
    }

    func startMonitoring() {
        guard timer == nil else { return }
        pollMicrophone()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMicrophone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func playManually() {
        isPausedForCall = false
        shouldResumeAfterCall = false
        audio.start()
    }

    func stopManually() {
        isPausedForCall = false
        shouldResumeAfterCall = false
        audio.stop()
    }

    func togglePlaybackManually() {
        audio.isPlaying ? stopManually() : playManually()
    }

    private func pollMicrophone() {
        update(rawCallActive: Self.isHeadsetCallRouteActive(), now: Date())
    }

    /// Debouncing avoids treating a calling app's brief device checks as a call.
    func update(rawCallActive: Bool, now: Date) {
        if rawCallActive != candidateState {
            candidateState = rawCallActive
            candidateSince = now
        }

        let requiredDuration = candidateState ? 0.8 : 1.2
        guard candidateState != isCallActive,
              now.timeIntervalSince(candidateSince) >= requiredDuration else { return }

        isCallActive = candidateState
        applyCallState()
    }

    private func applyCallState() {
        guard isEnabled else { return }

        if isCallActive {
            if audio.isPlaying {
                shouldResumeAfterCall = true
                isPausedForCall = true
                audio.stop()
            }
        } else {
            resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        let shouldResume = shouldResumeAfterCall
        shouldResumeAfterCall = false
        isPausedForCall = false
        if shouldResume { audio.start() }
    }

    nonisolated private static func isHeadsetCallRouteActive() -> Bool {
        guard let inputID = defaultDevice(for: kAudioHardwarePropertyDefaultInputDevice),
              let outputID = defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice) else {
            return false
        }
        return isCallRoute(inputDeviceID: inputID, outputDeviceID: outputID)
    }

    nonisolated private static func defaultDevice(
        for selector: AudioObjectPropertySelector
    ) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    nonisolated static func isCallRoute(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID
    ) -> Bool {
        inputDeviceID == outputDeviceID
    }
}

/// Detects whether another process currently has an active Core Audio output
/// stream. It inspects only process activity metadata; it never captures or
/// analyzes another application's audio.
@MainActor
final class OtherAudioActivityController {
    private let audio: NoiseAudioController
    private var timer: Timer?

    init(audio: NoiseAudioController) {
        self.audio = audio
    }

    func startMonitoring() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard audio.isOtherAudioDuckingEnabled else {
            audio.updateOtherAudioPlaying(false)
            return
        }
        audio.updateOtherAudioPlaying(Self.isAnotherProcessProducingAudio())
    }

    nonisolated private static func isAnotherProcessProducingAudio() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return processObjectIDs().contains { objectID in
            guard let processID = processID(for: objectID), processID != ownPID else {
                return false
            }
            if let ownBundleIdentifier,
               NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
                == ownBundleIdentifier {
                return false
            }
            return isRunningOutput(processObjectID: objectID)
        }
    }

    nonisolated private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else { return [] }

        var objectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        guard !objectIDs.isEmpty else { return [] }
        let status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        return status == noErr ? objectIDs : []
    }

    nonisolated private static func processID(for objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t.zero
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            &pid
        ) == noErr else { return nil }
        return pid
    }

    nonisolated private static func isRunningOutput(processObjectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning = UInt32.zero
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &byteCount,
            &isRunning
        ) == noErr else { return false }
        return isRunning != 0
    }
}
