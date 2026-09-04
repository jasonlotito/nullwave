import AVFoundation
import SwiftUI

@main
struct NullwaveIOSApp: App {
    @StateObject private var audio = NoiseAudioController()

    var body: some Scene {
        WindowGroup {
            RootView(audio: audio)
                .tint(.indigo)
                .onReceive(NotificationCenter.default.publisher(
                    for: AVAudioSession.interruptionNotification
                )) { notification in
                    audio.handleAudioSessionInterruption(notification)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: AVAudioSession.routeChangeNotification
                )) { notification in
                    audio.handleAudioRouteChange(notification)
                }
        }
    }
}

private struct RootView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        TabView {
            ListenView(audio: audio)
                .tabItem { Label("Listen", systemImage: "waveform") }
            SoundLibraryView(audio: audio)
                .tabItem { Label("Sounds", systemImage: "square.grid.2x2") }
            IOSSettingsView(audio: audio)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

private struct ListenView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        NavigationStack {
            ZStack {
                NullwaveBackground()
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 18)
                        nowPlaying
                        favoritePicker
                        volumeControl
                        mixingNotice
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 34)
                }
            }
            .navigationTitle("Nullwave")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.indigo.opacity(0.13))
                    .frame(width: 190, height: 190)
                Circle()
                    .stroke(.indigo.opacity(0.22), lineWidth: 1)
                    .frame(width: 156, height: 156)
                Image(systemName: audio.kind.symbolName)
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 5) {
                Text(audio.kind.displayName)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(audio.isPlaying ? "Playing with other audio" : "Ready to play")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Button {
                audio.toggle()
            } label: {
                Label(
                    audio.isPlaying ? "Stop" : "Play",
                    systemImage: audio.isPlaying ? "stop.fill" : "play.fill"
                )
                .font(.headline)
                .frame(minWidth: 126, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityHint(audio.isPlaying
                ? "Stops Nullwave. Other audio keeps playing."
                : "Plays \(audio.kind.displayName) while allowing other apps to keep playing.")

            if let error = audio.playbackErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Playback error: \(error)")
            }
        }
    }

    private var favoritePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(audio.favoriteKinds) { kind in
                    Button {
                        audio.kind = kind
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.symbolName)
                                .font(.title3)
                                .accessibilityHidden(true)
                            Text(kind.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(audio.kind == kind ? Color.white : Color.primary)
                    .background(
                        audio.kind == kind ? Color.indigo : Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .accessibilityLabel(kind.displayName)
                    .accessibilityValue(audio.kind == kind ? "Selected" : "Not selected")
                    .accessibilityHint("Selects \(kind.displayName) noise.")
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nullwave volume")
                    .font(.headline)
                Spacer()
                Text("\(volumePercent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
                Slider(value: $audio.volume, in: 0...1, step: 0.01)
                    .accessibilityLabel("Nullwave volume")
                    .accessibilityValue("\(volumePercent) percent")
                    .accessibilityHint("Adjusts Nullwave independently of the iPhone and other apps.")
                Image(systemName: "speaker.wave.3.fill")
                    .accessibilityHidden(true)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var mixingNotice: some View {
        Label {
            Text("Nullwave mixes with music, podcasts, and video, and continues when you lock your device.")
        } icon: {
            Image(systemName: "waveform.badge.plus")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private var volumePercent: Int { Int((audio.volume * 100).rounded()) }
}

private struct SoundLibraryView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        NavigationStack {
            List(NoiseKind.allCases) { kind in
                NavigationLink {
                    SoundDetailView(audio: audio, kind: kind)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbolName)
                            .font(.title3)
                            .foregroundStyle(.indigo)
                            .frame(width: 34)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName)
                                .font(.headline)
                            Text(kind.spectrum)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if audio.kind == kind {
                            Image(systemName: audio.isPlaying ? "waveform" : "checkmark")
                                .foregroundStyle(.indigo)
                                .accessibilityLabel(audio.isPlaying ? "Currently playing" : "Current sound")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Sounds")
        }
    }
}

private struct SoundDetailView: View {
    @ObservedObject var audio: NoiseAudioController
    let kind: NoiseKind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                description
                savedVolume
                favoriteControl
            }
            .padding(22)
        }
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { audio.stopPreview() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 54))
                .foregroundStyle(.indigo)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(kind.spectrum)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(audio.previewKind == kind ? "Stop Preview" : "Preview") {
                    audio.togglePreview(of: kind)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(audio.previewKind == kind
                    ? "Stops the preview and restores your previous sound."
                    : "Temporarily plays \(kind.displayName), then restores your previous sound.")

                Button(audio.kind == kind && audio.isPlaying ? "Playing" : "Play Sound") {
                    audio.stopPreview()
                    audio.kind = kind
                    audio.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(audio.kind == kind && audio.isPlaying && audio.previewKind == nil)
                .accessibilityHint("Makes \(kind.displayName) the current sound and starts playback.")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(22)
        .background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About this sound").font(.headline)
            Text(kind.summary).foregroundStyle(.secondary)
            Text("Good for").font(.headline).padding(.top, 6)
            Text(kind.bestFor).foregroundStyle(.secondary)
        }
    }

    private var savedVolume: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved volume").font(.headline)
                Spacer()
                Text("\(savedVolumePercent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { audio.savedVolume(for: kind) },
                set: { audio.setSavedVolume($0, for: kind) }
            ), in: 0...1, step: 0.01)
            .accessibilityLabel("Saved volume for \(kind.displayName)")
            .accessibilityValue("\(savedVolumePercent) percent")
            .accessibilityHint(audio.previewKind == kind
                ? "Adjusts this preview and remembers the volume."
                : "Remembers the volume without changing another sound currently playing.")
            Text(audio.previewKind == kind
                ? "This adjusts the preview and is remembered for next time."
                : "Each sound keeps its own volume independently.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var favoriteControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites").font(.headline)
            Text(favoriteDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Menu {
                if let slot = favoriteSlot {
                    Button("Remove from Favorites", role: .destructive) {
                        audio.removeFavorite(kind)
                    }
                    .disabled(audio.favoriteKinds.count == 1)
                    Divider()
                    Text("Currently in slot \(slot + 1)")
                }
                ForEach(0..<3, id: \.self) { slot in
                    Button(favoriteActionTitle(slot: slot)) {
                        audio.setFavorite(at: slot, to: kind)
                    }
                    .disabled(slot > audio.favoriteKinds.count)
                    .disabled(audio.favoriteKinds.indices.contains(slot)
                        && audio.favoriteKinds[slot] == kind)
                }
            } label: {
                Label(
                    favoriteSlot.map { "Favorite · Slot \($0 + 1)" } ?? "Add to Favorites",
                    systemImage: favoriteSlot == nil ? "star" : "star.fill"
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private var savedVolumePercent: Int {
        Int((audio.savedVolume(for: kind) * 100).rounded())
    }

    private var favoriteSlot: Int? { audio.favoriteKinds.firstIndex(of: kind) }

    private var favoriteDescription: String {
        if let favoriteSlot {
            return "\(kind.displayName) appears in favorite slot \(favoriteSlot + 1) on the Listen screen."
        }
        return "Add \(kind.displayName) to one of the three shortcuts on the Listen screen."
    }

    private func favoriteActionTitle(slot: Int) -> String {
        if slot == audio.favoriteKinds.count { return "Add as Slot \(slot + 1)" }
        guard audio.favoriteKinds.indices.contains(slot) else { return "Slot \(slot + 1) unavailable" }
        let current = audio.favoriteKinds[slot].displayName
        return "Use Slot \(slot + 1) · Replace \(current)"
    }
}

private struct IOSSettingsView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    LabeledContent("Mix with other apps", value: "Always on")
                    LabeledContent("Background playback", value: "Enabled")
                    Text("Nullwave keeps playing when you use another app or lock your device. Music, podcasts, and video continue at their own volume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(Array(audio.favoriteKinds.enumerated()), id: \.element) { index, kind in
                        Menu {
                            ForEach(NoiseKind.allCases) { option in
                                Button {
                                    audio.setFavorite(at: index, to: option)
                                } label: {
                                    Label(option.displayName, systemImage: option.symbolName)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Favorite \(index + 1)")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(kind.displayName)
                                Image(systemName: kind.symbolName)
                                    .frame(width: 24, alignment: .trailing)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("Favorite \(index + 1)")
                        .accessibilityValue(kind.displayName)
                        .accessibilityHint("Choose a sound for this Listen shortcut.")
                    }

                    if audio.favoriteKinds.count < 3 {
                        Menu {
                            ForEach(NoiseKind.allCases.filter {
                                !audio.favoriteKinds.contains($0)
                            }) { kind in
                                Button(kind.displayName) {
                                    audio.setFavorite(at: audio.favoriteKinds.count, to: kind)
                                }
                            }
                        } label: {
                            Label("Add Favorite", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("Listen shortcuts")
                } footer: {
                    Text("Choose up to three sounds for fast access from the Listen screen.")
                }

                Section("About") {
                    LabeledContent("App", value: "Nullwave for iOS")
                    LabeledContent("Sounds", value: "11 generated locally")
                    Link("Nullwave website", destination: URL(string: "https://nullwaveapp.com/")!)
                    Text("No account, analytics, ads, audio files, or network connection required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct NullwaveBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.indigo.opacity(0.10), Color.clear, Color.cyan.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
