import AVFoundation
import SwiftUI

@main
struct NullwaveIOSApp: App {
    @StateObject private var audio = NullwaveIntentPlayback.audio

    var body: some Scene {
        WindowGroup {
            RootView(audio: audio)
                .tint(.nullwavePurpleBright)
                .preferredColorScheme(.dark)
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
                .onReceive(NotificationCenter.default.publisher(
                    for: AVAudioSession.silenceSecondaryAudioHintNotification
                )) { _ in
                    audio.refreshOtherAudioState()
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
        .toolbarBackground(Color.nullwaveBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct ListenView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.height < 760
                let landscape = geometry.size.width > geometry.size.height
                ScrollView {
                    listenContent(compact: compact, landscape: landscape)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(NullwaveBackground())
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func listenContent(compact: Bool, landscape: Bool) -> some View {
        Group {
            if landscape {
                HStack(spacing: 14) {
                    nowPlaying(compact: true)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        favoritePicker(compact: true)
                        volumeControl(compact: true)
                        mixingNotice
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: compact ? 10 : 20) {
                    nowPlaying(compact: compact)
                    favoritePicker(compact: compact)
                    volumeControl(compact: compact)
                    mixingNotice
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 22)
        .padding(.top, landscape ? 4 : (compact ? 6 : 16))
        .padding(.bottom, landscape ? 4 : (compact ? 8 : 22))
    }

    private func nowPlaying(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 12) {
            Image("NullwaveLogo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 88 : 132, height: compact ? 88 : 132)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 20 : 29))
                .shadow(color: .nullwavePurple.opacity(0.34), radius: 24)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text(audio.kind.displayName)
                    .font(.system(compact ? .title : .largeTitle, design: .rounded, weight: .bold))
                Text(playbackDescription)
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(Color.nullwaveMuted)
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
                .frame(minWidth: 138, minHeight: compact ? 44 : 50)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(
                        colors: [.nullwavePurple, .nullwaveBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
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

    private func favoritePicker(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 11) {
            Text("Favorites")
                .font(.headline)
            HStack(spacing: compact ? 7 : 10) {
                ForEach(audio.favoriteKinds) { kind in
                    Button {
                        audio.kind = kind
                    } label: {
                        VStack(spacing: compact ? 5 : 8) {
                            Image(systemName: kind.symbolName)
                                .font(compact ? .body : .title3)
                                .accessibilityHidden(true)
                            Text(kind.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: compact ? 52 : 68)
                        .background(
                            audio.kind == kind ? Color.nullwavePurple : Color.white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(audio.kind == kind ? Color.white : Color.primary)
                    .accessibilityLabel(kind.displayName)
                    .accessibilityValue(audio.kind == kind ? "Selected" : "Not selected")
                    .accessibilityHint("Selects \(kind.displayName) noise.")
                }
            }
        }
        .padding(compact ? 12 : 17)
        .nullwavePanel(cornerRadius: 22)
    }

    private func volumeControl(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 13) {
            volumeSlider(
                title: "Volume",
                value: $audio.volume,
                hint: "Adjusts Nullwave when no other audio is playing.",
                compact: compact
            )

            Divider().overlay(Color.nullwaveLine)

            volumeSlider(
                title: "Volume while other audio is playing",
                value: $audio.otherAudioVolume,
                hint: "Adjusts Nullwave while another app is playing audio.",
                compact: compact
            )
        }
        .padding(compact ? 12 : 17)
        .nullwavePanel(cornerRadius: 22)
    }

    private func volumeSlider(
        title: String,
        value: Binding<Double>,
        hint: String,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            HStack {
                Text(title)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Color.nullwaveMuted)
            }
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").accessibilityHidden(true)
                Slider(value: value, in: 0...1, step: 0.01)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
                    .accessibilityHint(hint)
                Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            }
        }
    }

    private var mixingNotice: some View {
        Label {
            Text("Nullwave mixes with music, podcasts, and video, and continues when you lock your device.")
        } icon: {
            Image(systemName: "waveform.badge.plus")
        }
        .font(.footnote)
        .foregroundStyle(Color.nullwaveMuted)
        .padding(.horizontal, 6)
    }

    private var playbackDescription: String {
        if audio.isPlaying && audio.isOtherAudioPlaying { return "Other audio detected" }
        return audio.isPlaying ? "Playing" : "Ready to play"
    }
}

private struct SoundLibraryView: View {
    @ObservedObject var audio: NoiseAudioController

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NullwaveScreenHeader(title: "Sounds")

                List(NoiseKind.allCases) { kind in
                    NavigationLink {
                        SoundDetailView(audio: audio, kind: kind)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: kind.symbolName)
                                .font(.title3)
                                .foregroundStyle(Color.nullwavePurpleBright)
                                .frame(width: 34)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.displayName)
                                    .font(.headline)
                                Text(kind.spectrum)
                                    .font(.caption)
                                    .foregroundStyle(Color.nullwaveMuted)
                            }
                            Spacer()
                            if audio.kind == kind {
                                Image(systemName: audio.isPlaying ? "waveform" : "checkmark")
                                    .foregroundStyle(Color.nullwaveBlue)
                                    .accessibilityLabel(audio.isPlaying ? "Currently playing" : "Current sound")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.nullwavePanel.opacity(0.88))
                }
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(NullwaveBackground())
            .toolbar(.hidden, for: .navigationBar)
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
        .background(NullwaveBackground())
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.nullwaveBackground.opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onDisappear { audio.stopPreview() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 54))
                .foregroundStyle(Color.nullwavePurpleBright)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(kind.spectrum)
                .font(.subheadline)
                .foregroundStyle(Color.nullwaveMuted)
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
        .nullwavePanel(cornerRadius: 24)
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About this sound").font(.headline)
            Text(kind.summary).foregroundStyle(Color.nullwaveMuted)
            Text("Good for").font(.headline).padding(.top, 6)
            Text(kind.bestFor).foregroundStyle(Color.nullwaveMuted)
        }
    }

    private var savedVolume: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Volume").font(.headline)
                Spacer()
                Text("\(savedVolumePercent)%")
                    .monospacedDigit()
                    .foregroundStyle(Color.nullwaveMuted)
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
                : "Used when no other audio is playing.")
                .font(.footnote)
                .foregroundStyle(Color.nullwaveMuted)

            Divider().overlay(Color.nullwaveLine)

            HStack {
                Text("Volume while other audio is playing").font(.headline)
                Spacer()
                Text("\(savedOtherAudioVolumePercent)%")
                    .monospacedDigit()
                    .foregroundStyle(Color.nullwaveMuted)
            }
            Slider(value: Binding(
                get: { audio.savedOtherAudioVolume(for: kind) },
                set: { audio.setSavedOtherAudioVolume($0, for: kind) }
            ), in: 0...1, step: 0.01)
            .accessibilityLabel("Volume for \(kind.displayName) while other audio is playing")
            .accessibilityValue("\(savedOtherAudioVolumePercent) percent")
            .accessibilityHint("Remembers the volume used when another app is playing audio.")
            Text("Moves to this level over 200 milliseconds, then returns to normal over 400 milliseconds.")
                .font(.footnote)
                .foregroundStyle(Color.nullwaveMuted)
        }
        .padding(18)
        .nullwavePanel(cornerRadius: 18)
    }

    private var favoriteControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites").font(.headline)
            Text(favoriteDescription)
                .font(.footnote)
                .foregroundStyle(Color.nullwaveMuted)
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

    private var savedOtherAudioVolumePercent: Int {
        Int((audio.savedOtherAudioVolume(for: kind) * 100).rounded())
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
        VStack(spacing: 0) {
            NullwaveScreenHeader(title: "Settings")

            Form {
                Section("Playback") {
                    LabeledContent("Mix with other apps", value: "Always on")
                    LabeledContent("Background playback", value: "Enabled")
                    Text("Nullwave keeps playing when you use another app or lock your device. Music, podcasts, and video continue at their own volume.")
                        .font(.footnote)
                        .foregroundStyle(Color.nullwaveMuted)
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
                        .foregroundStyle(Color.nullwaveMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(NullwaveBackground())
    }
}

private struct NullwaveScreenHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .nullwavePurpleBright],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [Color.nullwavePurple.opacity(0.20), Color.nullwaveBackground.opacity(0.96)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.nullwaveLine)
                .frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NullwaveBackground: View {
    var body: some View {
        ZStack {
            Color.nullwaveBackground
            RadialGradient(
                colors: [Color.nullwavePurple.opacity(0.25), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color.nullwaveBlue.opacity(0.10), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct NullwavePanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Color.nullwavePanel.opacity(0.90),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.nullwaveLine, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}

private extension View {
    func nullwavePanel(cornerRadius: CGFloat) -> some View {
        modifier(NullwavePanelModifier(cornerRadius: cornerRadius))
    }
}

private extension Color {
    static let nullwaveBackground = Color(red: 6 / 255, green: 7 / 255, blue: 20 / 255)
    static let nullwavePanel = Color(red: 17 / 255, green: 20 / 255, blue: 38 / 255)
    static let nullwaveMuted = Color(red: 170 / 255, green: 170 / 255, blue: 192 / 255)
    static let nullwavePurple = Color(red: 118 / 255, green: 82 / 255, blue: 255 / 255)
    static let nullwavePurpleBright = Color(red: 161 / 255, green: 140 / 255, blue: 255 / 255)
    static let nullwaveBlue = Color(red: 48 / 255, green: 200 / 255, blue: 255 / 255)
    static let nullwaveLine = Color(red: 172 / 255, green: 181 / 255, blue: 255 / 255).opacity(0.18)
}
