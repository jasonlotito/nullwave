import AppIntents
import Foundation

enum NullwaveSharedDefaults {
    static let suiteName = "group.com.jasonlotito.nullwave"
    static let playbackIsActiveKey = "playbackIsActive"
    static let favoriteKindsKey = "favoriteNoiseKinds"
    static let selectedKindKey = "noiseKind"

    static var store: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func preparedAppStore() -> UserDefaults {
        let shared = store
        let migrationKey = "sharedDefaultsMigrationVersion"
        guard shared.integer(forKey: migrationKey) < 1 else { return shared }

        let standard = UserDefaults.standard
        for (key, value) in standard.dictionaryRepresentation() where
            key == selectedKindKey
                || key == favoriteKindsKey
                || key == "noiseVolume"
                || key.hasPrefix("noiseVolume.")
                || key.hasPrefix("otherAudioVolume.") {
            shared.set(value, forKey: key)
        }
        shared.set(1, forKey: migrationKey)
        return shared
    }
}

struct ToggleNullwavePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Stop Nullwave"
    static let description = IntentDescription(
        "Starts Nullwave with the selected sound, or stops it when it is already playing."
    )

    func perform() async throws -> some IntentResult {
#if NULLWAVE_IOS_APP
        await NullwaveIntentPlayback.performToggle()
#endif
        return .result()
    }
}

struct PlayNullwaveFavoriteIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Nullwave Favorite"
    static let description = IntentDescription("Starts one of the three favorite Nullwave sounds.")

    @Parameter(title: "Favorite Number")
    var slot: Int

    init() {
        slot = 0
    }

    init(slot: Int) {
        self.slot = slot
    }

    func perform() async throws -> some IntentResult {
#if NULLWAVE_IOS_APP
        await NullwaveIntentPlayback.playFavorite(at: slot)
#endif
        return .result()
    }
}
