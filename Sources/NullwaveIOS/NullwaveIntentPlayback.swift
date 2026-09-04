import Foundation
import WidgetKit

@MainActor
enum NullwaveIntentPlayback {
    static let audio = NoiseAudioController(
        defaults: NullwaveSharedDefaults.preparedAppStore()
    )

    static func performToggle() {
        audio.toggle()
        reloadWidgets()
    }

    static func playFavorite(at slot: Int) {
        guard audio.favoriteKinds.indices.contains(slot) else { return }
        audio.stopPreview()
        audio.kind = audio.favoriteKinds[slot]
        audio.start()
        reloadWidgets()
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
