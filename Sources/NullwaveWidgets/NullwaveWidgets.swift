import SwiftUI
import WidgetKit

private struct NullwaveWidgetFavorite: Identifiable {
    let rawValue: String
    let displayName: String
    let symbolName: String
    let slot: Int

    var id: Int { slot }

    init(rawValue: String, slot: Int) {
        self.rawValue = rawValue
        self.slot = slot
        displayName = rawValue.capitalized
        symbolName = switch rawValue {
        case "dark": "moon.fill"
        case "brown": "mountain.2.fill"
        case "pink": "heart.fill"
        case "white": "sparkles"
        case "gray": "circle.lefthalf.filled"
        case "blue": "wind"
        case "violet": "waveform.path"
        case "deep": "arrow.down.to.line.compact"
        case "fan": "fan.fill"
        case "cabin": "airplane"
        case "ocean": "water.waves"
        default: "waveform"
        }
    }
}

private struct NullwaveWidgetEntry: TimelineEntry {
    let date: Date
    let isPlaying: Bool
    let selectedKind: String
    let favorites: [NullwaveWidgetFavorite]
}

private struct NullwaveWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NullwaveWidgetEntry {
        makeEntry(preview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NullwaveWidgetEntry) -> Void) {
        completion(makeEntry(preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NullwaveWidgetEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry(preview: false)], policy: .never))
    }

    private func makeEntry(preview: Bool) -> NullwaveWidgetEntry {
        let store = NullwaveSharedDefaults.store
        let rawFavorites = preview
            ? ["dark", "brown", "pink"]
            : store.stringArray(forKey: NullwaveSharedDefaults.favoriteKindsKey)
                ?? ["dark", "brown", "pink"]
        return NullwaveWidgetEntry(
            date: .now,
            isPlaying: preview
                ? false
                : store.bool(forKey: NullwaveSharedDefaults.playbackIsActiveKey),
            selectedKind: preview
                ? "dark"
                : store.string(forKey: NullwaveSharedDefaults.selectedKindKey) ?? "dark",
            favorites: rawFavorites.prefix(3).enumerated().map {
                NullwaveWidgetFavorite(rawValue: $0.element, slot: $0.offset)
            }
        )
    }
}

private struct NullwaveWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NullwaveWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: ToggleNullwavePlaybackIntent()) {
                Image(systemName: entry.isPlaying ? "stop.fill" : "waveform")
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isPlaying ? "Stop Nullwave" : "Play Nullwave")
        default:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(entry.favorites.prefix(2)) { favorite in
                        favoriteButton(favorite)
                    }
                }
                HStack(spacing: 8) {
                    if entry.favorites.count > 2 {
                        favoriteButton(entry.favorites[2])
                    } else {
                        Color.clear
                    }
                    playbackButton
                }
            }
            .padding(4)
        }
    }

    private func favoriteButton(_ favorite: NullwaveWidgetFavorite) -> some View {
        Button(intent: PlayNullwaveFavoriteIntent(slot: favorite.slot)) {
            VStack(spacing: 4) {
                Image(systemName: favorite.symbolName)
                    .font(.headline)
                Text(favorite.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(entry.selectedKind == favorite.rawValue ? .white : .primary)
            .background(
                entry.selectedKind == favorite.rawValue
                    ? Color(red: 0.39, green: 0.30, blue: 0.96)
                    : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(favorite.displayName)")
    }

    private var playbackButton: some View {
        Button(intent: ToggleNullwavePlaybackIntent()) {
            VStack(spacing: 4) {
                Image(systemName: entry.isPlaying ? "stop.fill" : "play.fill")
                    .font(.headline)
                Text(entry.isPlaying ? "Stop" : "Play")
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.43, green: 0.27, blue: 0.96),
                        Color(red: 0.10, green: 0.52, blue: 0.95)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.isPlaying ? "Stop Nullwave" : "Play Nullwave")
    }
}

private struct NullwaveHomeAndLockWidget: Widget {
    static let kind = "com.jasonlotito.nullwave.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NullwaveWidgetProvider()) { entry in
            NullwaveWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.035, green: 0.04, blue: 0.10),
                            Color(red: 0.08, green: 0.05, blue: 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Nullwave Controls")
        .description("Play a favorite sound or start and stop Nullwave.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private struct NullwavePlaybackControl: ControlWidget {
    static let kind = "com.jasonlotito.nullwave.playback-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleNullwavePlaybackIntent()) {
                Label("Nullwave", systemImage: "waveform")
            }
        }
        .displayName("Play or Stop Nullwave")
        .description("Starts the selected Nullwave sound or stops playback.")
    }
}

@main
struct NullwaveWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NullwaveHomeAndLockWidget()
        NullwavePlaybackControl()
    }
}
