import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = NoiseAudioController()
    private lazy var callActivity = CallActivityController(audio: audio)
    private let loginItem = LaunchAtLoginController()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?
    private var playbackObserver: AnyCancellable?
    private var commandObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let appIcon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = appIcon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = menuBarIcon()
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel("Nullwave")
        button.toolTip = "Nullwave — click to play"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        playbackObserver = audio.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 230)
        popover.contentViewController = NSHostingController(
            rootView: QuickControlsView(
                audio: audio,
                callActivity: callActivity,
                openSettings: { [weak self] in self?.showSettingsWindow() }
            )
        )

        if !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button else { return }
                self.showSettings(relativeTo: button)
            }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }

        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jasonlotito.nullwave.control"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let command = notification.userInfo?["command"] as? String
            let stringValue = notification.userInfo?["value"] as? String
            let numberValue = (notification.userInfo?["value"] as? NSNumber)?.doubleValue
            Task { @MainActor in
                self?.handleCommand(command, stringValue: stringValue, numberValue: numberValue)
            }
        }

        callActivity.startMonitoring()

        if CommandLine.arguments.contains("--enable-launch-at-login")
            || CommandLine.arguments.contains("--resume-playback") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if CommandLine.arguments.contains("--resume-playback") {
                    self.audio.start()
                }
                if CommandLine.arguments.contains("--enable-launch-at-login") {
                    self.loginItem.setEnabled(true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stop()
        callActivity.stopMonitoring()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let commandObserver {
            DistributedNotificationCenter.default().removeObserver(commandObserver)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings(relativeTo: sender)
        } else {
            callActivity.togglePlaybackManually()
        }
    }

    private func showSettings(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            loginItem.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showSettingsWindow() {
        popover.performClose(nil)

        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: FullSettingsView(
                    audio: audio,
                    callActivity: callActivity,
                    loginItem: loginItem,
                    checkForUpdates: { [weak self] in
                        self?.updaterController.checkForUpdates(nil)
                    },
                    quit: { NSApp.terminate(nil) }
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "Nullwave Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 760, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }

        loginItem.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            audio.stopPreview()
        }
    }

    private func updateStatusItem() {
        statusItem.button?.image = menuBarIcon()
        let status = callActivity.isPausedForCall
            ? "paused for call"
            : (audio.isPlaying ? "playing" : "stopped")
        statusItem.button?.setAccessibilityLabel("Nullwave \(status)")
        statusItem.button?.toolTip = "Nullwave — \(status)"
    }

    private func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Nullwave")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Nullwave"
        return image
    }

    private func handleCommand(_ command: String?, stringValue: String?, numberValue: Double?) {
        guard let command else { return }

        switch command {
        case "play":
            callActivity.playManually()
        case "stop":
            callActivity.stopManually()
        case "toggle":
            callActivity.togglePlaybackManually()
        case "volume":
            if let numberValue {
                audio.volume = numberValue
            }
        case "noise":
            if let stringValue,
               let kind = NoiseKind(rawValue: stringValue) {
                audio.kind = kind
            }
        default:
            break
        }
    }
}

@main
enum NullwaveApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

private struct QuickControlsView: View {
    @ObservedObject var audio: NoiseAudioController
    @ObservedObject var callActivity: CallActivityController
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: audio.isPlaying ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title)
                    .foregroundStyle(audio.isPlaying ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nullwave").font(.headline)
                    Text("\(audio.kind.displayName) · \(playbackStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(audio.isPlaying ? "Stop" : "Play") {
                    callActivity.togglePlaybackManually()
                }
                    .keyboardShortcut(.space, modifiers: [])
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Favorites").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Picker("Sound", selection: $audio.kind) {
                        ForEach(audio.favoriteKinds) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(audio.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $audio.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                }
            }

            Divider()
            Button(action: openSettings) {
                HStack {
                    Image(systemName: "gearshape")
                    Text("Open Nullwave Settings…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var playbackStatus: String {
        if callActivity.isPausedForCall { return "Paused for call" }
        return audio.isPlaying ? "Playing" : "Stopped"
    }
}

private enum SettingsDestination: Hashable {
    case general
    case sound(NoiseKind)
    case about
}

private struct FullSettingsView: View {
    @ObservedObject var audio: NoiseAudioController
    @ObservedObject var callActivity: CallActivityController
    @ObservedObject var loginItem: LaunchAtLoginController
    let checkForUpdates: () -> Void
    let quit: () -> Void
    @State private var selection: SettingsDestination

    init(
        audio: NoiseAudioController,
        callActivity: CallActivityController,
        loginItem: LaunchAtLoginController,
        checkForUpdates: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.audio = audio
        self.callActivity = callActivity
        self.loginItem = loginItem
        self.checkForUpdates = checkForUpdates
        self.quit = quit
        _selection = State(initialValue: .sound(audio.kind))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("General", systemImage: "gearshape")
                        .tag(SettingsDestination.general)
                }

                Section("Sounds") {
                    ForEach(NoiseKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName)
                            .tag(SettingsDestination.sound(kind))
                    }
                }

                Section {
                    Label("About Nullwave", systemImage: "info.circle")
                        .tag(SettingsDestination.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            switch selection {
            case .general:
                generalSettings
            case .sound(let kind):
                soundDetail(for: kind)
            case .about:
                aboutSettings
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: selection) { _, _ in
            audio.stopPreview()
        }
        .onDisappear { audio.stopPreview() }
    }

    private func soundDetail(for kind: NoiseKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.displayName)
                            .font(.largeTitle.bold())
                        Text(kind.spectrum)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if audio.previewKind == kind {
                        Button("Stop Preview") {
                            audio.togglePreview(of: kind)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                    } else {
                        Button("Preview") {
                            audio.togglePreview(of: kind)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("About this sound").font(.headline)
                    Text(kind.summary)
                        .foregroundStyle(.secondary)
                    Text("Good for").font(.headline).padding(.top, 4)
                    Text(kind.bestFor)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Saved volume for \(kind.displayName)").font(.headline)
                        Spacer()
                        Text("\(Int(audio.savedVolume(for: kind) * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(
                            get: { audio.savedVolume(for: kind) },
                            set: { audio.setSavedVolume($0, for: kind) }
                        ), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Text(audio.previewKind == kind
                        ? "Adjusts this preview and remembers the volume for next time."
                        : "This volume is remembered without changing the sound currently playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                favoriteControl(for: kind)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func favoriteControl(for kind: NoiseKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick controls").font(.headline)
            Text(favoriteDescription(for: kind))
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                if favoriteSlot(for: kind) != nil {
                    Button("Remove from Favorites", role: .destructive) {
                        audio.removeFavorite(kind)
                    }
                    .disabled(audio.favoriteKinds.count == 1)
                    Divider()
                }
                ForEach(0..<3, id: \.self) { index in
                    Button(favoriteActionTitle(for: kind, slot: index)) {
                        audio.setFavorite(at: index, to: kind)
                    }
                    .disabled(index > audio.favoriteKinds.count)
                    .disabled(
                        audio.favoriteKinds.indices.contains(index)
                            && audio.favoriteKinds[index] == kind
                    )
                }
            } label: {
                Label(
                    favoriteSlot(for: kind).map { "Favorite · Slot \($0 + 1)" }
                        ?? "Make This a Favorite…",
                    systemImage: favoriteSlot(for: kind) == nil ? "star" : "star.fill"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    Text("General")
                        .font(.largeTitle.bold())
                }

                GroupBox("Call Mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Detect headset call mode", isOn: $callActivity.isEnabled)
                            .toggleStyle(.switch)
                        Text(callActivity.isPausedForCall
                            ? "The same device is handling input and output. Nullwave will resume when that route changes."
                            : "When the same device is selected for system input and output, Nullwave pauses until that route changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Launch Nullwave at Login",
                            isOn: Binding(
                                get: { loginItem.isRegistered },
                                set: {
                                    loginItem.setEnabled(
                                        $0,
                                        resumePlaybackAfterInstall: callActivity.shouldResumePlaybackAfterRelaunch
                                    )
                                }
                            )
                        )
                        .toggleStyle(.switch)

                        if loginItem.requiresApproval {
                            Button("Approval required — Open Login Items") {
                                loginItem.openLoginItemSettings()
                            }
                            .font(.caption)
                        } else if let errorMessage = loginItem.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Updates") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Automatic update checks are enabled.")
                            Text("Nullwave checks once a day and always asks before installing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check for Updates…", action: checkForUpdates)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                favoritesEditor

                Divider()
                HStack {
                    Spacer()
                    Button("Quit Nullwave", action: quit)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let icon = aboutIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 128, height: 128)
                        .accessibilityLabel("Nullwave logo")
                } else {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 5) {
                    Text("Nullwave")
                        .font(.largeTitle.bold())
                    Text(versionDescription)
                        .foregroundStyle(.secondary)
                }

                Text("A native macOS menu-bar app that generates soothing noise in real time, with independent volume, quick favorites, previews, and optional headset call-mode detection.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 470)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Project") {
                            Link(
                                "github.com/jasonlotito/nullwave",
                                destination: URL(string: "https://github.com/jasonlotito/nullwave")!
                            )
                        }
                        Divider()
                        LabeledContent("Author") {
                            Link(
                                "Jason Lotito",
                                destination: URL(string: "https://github.com/jasonlotito")!
                            )
                        }
                    }
                    .padding(6)
                }
                .frame(maxWidth: 520)

                Text("Copyright © 2026 Jason Lotito")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private var favoritesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick-control favorites").font(.headline)
            Text("Choose the three sounds shown in the menu-bar panel. Drag to change their order, or choose a slot from any sound page.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(audio.favoriteKinds.enumerated()), id: \.element) { index, kind in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Picker("Favorite \(index + 1)", selection: Binding(
                        get: { audio.favoriteKinds[index] },
                        set: { audio.setFavorite(at: index, to: $0) }
                    )) {
                        ForEach(NoiseKind.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .draggable(kind.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let rawValue = items.first,
                          let source = NoiseKind(rawValue: rawValue) else { return false }
                    audio.moveFavorite(source, before: kind)
                    return true
                }
            }

            if audio.favoriteKinds.count < 3 {
                Menu {
                    ForEach(NoiseKind.allCases.filter { !audio.favoriteKinds.contains($0) }) { kind in
                        Button {
                            audio.setFavorite(at: audio.favoriteKinds.count, to: kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("Add Favorite", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func favoriteSlot(for kind: NoiseKind) -> Int? {
        audio.favoriteKinds.firstIndex(of: kind)
    }

    private var aboutIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else {
            return NSApp.applicationIconImage
        }
        return NSImage(contentsOf: url)
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
        return "Version \(version) (\(build))"
    }

    private func favoriteDescription(for kind: NoiseKind) -> String {
        if let slot = favoriteSlot(for: kind) {
            return "\(kind.displayName) is currently shown in favorite slot \(slot + 1)."
        }
        return "Add \(kind.displayName) to one of the three favorite slots in the menu-bar panel."
    }

    private func favoriteActionTitle(for kind: NoiseKind, slot: Int) -> String {
        if slot == audio.favoriteKinds.count {
            return "Add as Slot \(slot + 1)"
        }
        guard audio.favoriteKinds.indices.contains(slot) else {
            return "Slot \(slot + 1) unavailable"
        }
        let occupant = audio.favoriteKinds[slot].displayName
        if let currentSlot = favoriteSlot(for: kind) {
            if currentSlot == slot { return "Slot \(slot + 1) — Current" }
            return "Move to Slot \(slot + 1) — Swap with \(occupant)"
        }
        return "Put in Slot \(slot + 1) — Replace \(occupant)"
    }
}
