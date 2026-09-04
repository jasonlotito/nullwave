import AppKit
import Combine
import Sparkle
import SwiftUI

private extension Notification.Name {
    static let openNullwaveGeneralSettings = Notification.Name(
        "com.jasonlotito.nullwave.open-general-settings"
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let audio = NoiseAudioController()
    private lazy var callActivity = CallActivityController(audio: audio)
    private lazy var otherAudioActivity = OtherAudioActivityController(audio: audio)
    private let loginItem = LaunchAtLoginController()
    private let commandLineTool = CommandLineToolInstaller()
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
    private var duckingPreferenceObserver: AnyCancellable?
    private var commandObserver: NSObjectProtocol?
    private var playbackMenuItem: NSMenuItem?

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
        button.setAccessibilityHelp("Press to play or stop. Use the Nullwave menu for quick controls and settings.")
        button.toolTip = "Nullwave — click to play"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configureApplicationMenu()

        playbackObserver = audio.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }

        popover = NSPopover()
        popover.behavior = .transient
        updatePopoverAnimationPreference()
        popover.contentSize = quickControlsSize
        popover.contentViewController = NSHostingController(
            rootView: QuickControlsView(
                audio: audio,
                callActivity: callActivity,
                openSettings: { [weak self] in self?.showSettingsWindow() }
            )
        )

        duckingPreferenceObserver = audio.$isOtherAudioDuckingEnabled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.popover.contentSize = self?.quickControlsSize ?? .zero }
            }

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
        otherAudioActivity.startMonitoring()

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
        audio.shutdown()
        callActivity.stopMonitoring()
        otherAudioActivity.stopMonitoring()
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

    @objc private func togglePlayback() {
        callActivity.togglePlaybackManually()
    }

    @objc private func showQuickControls() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            presentQuickControls(relativeTo: button)
        }
    }

    @objc private func openSettings() {
        showSettingsWindow()
    }

    private func showSettings(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentQuickControls(relativeTo: button)
        }
    }

    private func presentQuickControls(relativeTo button: NSStatusBarButton) {
        loginItem.refresh()
        updatePopoverAnimationPreference()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updatePopoverAnimationPreference() {
        popover?.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Nullwave")

        let quickControlsItem = NSMenuItem(
            title: "Show Quick Controls",
            action: #selector(showQuickControls),
            keyEquivalent: "n"
        )
        quickControlsItem.keyEquivalentModifierMask = [.command, .shift]
        quickControlsItem.target = self
        appMenu.addItem(quickControlsItem)

        let playbackItem = NSMenuItem(
            title: "Play Nullwave",
            action: #selector(togglePlayback),
            keyEquivalent: "p"
        )
        playbackItem.keyEquivalentModifierMask = [.command, .shift]
        playbackItem.target = self
        playbackMenuItem = playbackItem
        appMenu.addItem(playbackItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Nullwave",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func showSettingsWindow() {
        popover.performClose(nil)

        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: FullSettingsView(
                    audio: audio,
                    callActivity: callActivity,
                    loginItem: loginItem,
                    commandLineTool: commandLineTool,
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
        commandLineTool.refresh()
        NotificationCenter.default.post(name: .openNullwaveGeneralSettings, object: nil)
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
        playbackMenuItem?.title = audio.isPlaying ? "Stop Nullwave" : "Play Nullwave"
    }

    private var quickControlsSize: NSSize {
        NSSize(width: 320, height: audio.isOtherAudioDuckingEnabled ? 300 : 230)
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
        case "other-volume":
            if let numberValue {
                audio.otherAudioVolume = numberValue
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

@MainActor
private final class CommandLineToolInstaller: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var errorMessage: String?

    let destinationPath = "/usr/local/bin/nullwavectl"

    init() {
        refresh()
    }

    func refresh() {
        guard let bundledToolURL else {
            isInstalled = false
            return
        }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        isInstalled = FileManager.default.fileExists(atPath: destinationPath)
            && destinationURL.resolvingSymlinksInPath().standardizedFileURL
                == bundledToolURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func install() {
        errorMessage = nil
        guard let bundledToolURL else {
            errorMessage = "The command-line tool is missing from this copy of Nullwave."
            return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            errorMessage = "Move Nullwave to Applications before installing its command-line tool."
            return
        }

        let explanation = NSAlert()
        explanation.alertStyle = .informational
        explanation.messageText = "Install nullwavectl?"
        explanation.informativeText = "Nullwave will create a symlink at /usr/local/bin/nullwavectl so you can control the running app from Terminal. Because /usr/local/bin is system-owned, macOS will ask for an administrator password. No app data or system settings will be changed."
        explanation.addButton(withTitle: "Install")
        explanation.addButton(withTitle: "Cancel")
        guard explanation.runModal() == .alertFirstButtonReturn else { return }

        let command = [
            "/bin/mkdir -p \(shellQuoted("/usr/local/bin"))",
            "/bin/ln -sfn \(shellQuoted(bundledToolURL.path)) \(shellQuoted(destinationPath))"
        ].joined(separator: " && ")
        let appleScriptCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(
            source: "do shell script \"\(appleScriptCommand)\" with administrator privileges"
        ) else {
            errorMessage = "Nullwave could not prepare the command-line tool installer."
            return
        }

        var scriptError: NSDictionary?
        script.executeAndReturnError(&scriptError)
        if let scriptError {
            let number = scriptError[NSAppleScript.errorNumber] as? Int
            errorMessage = number == -128
                ? "Installation was canceled."
                : (scriptError[NSAppleScript.errorMessage] as? String
                    ?? "Nullwave could not install the command-line tool.")
            refresh()
            return
        }

        refresh()
        if !isInstalled {
            errorMessage = "The command-line tool was installed, but Nullwave could not verify it."
        }
    }

    private var bundledToolURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/nullwavectl", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                    .accessibilityHidden(true)
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
                    .accessibilityHint(audio.isPlaying
                        ? "Stops the current noise."
                        : "Starts \(audio.kind.displayName) noise.")
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
                    .accessibilityLabel("Favorite sound")
                    .accessibilityValue(audio.kind.displayName)
                    .accessibilityHint("Choose a favorite sound to play.")
                    Spacer(minLength: 0)
                }
            }

            quickVolumeControl(
                title: "Volume",
                value: $audio.volume,
                accessibilityHint: "Adjusts Nullwave when no other audio is playing."
            )

            if audio.isOtherAudioDuckingEnabled {
                quickVolumeControl(
                    title: "Volume while other audio is playing",
                    value: $audio.otherAudioVolume,
                    accessibilityHint: "Adjusts Nullwave while another app is playing audio."
                )
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
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityHint("Opens the full Nullwave settings window.")
        }
        .padding(16)
        .frame(width: 320)
    }

    private var playbackStatus: String {
        if callActivity.isPausedForCall { return "Paused for call" }
        if audio.isPlaying && audio.isOtherAudioDuckingEnabled && audio.isOtherAudioPlaying {
            return "Playing · other audio detected"
        }
        return audio.isPlaying ? "Playing" : "Stopped"
    }

    private func quickVolumeControl(
        title: String,
        value: Binding<Double>,
        accessibilityHint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "speaker.fill").accessibilityHidden(true)
                Slider(value: value, in: 0...1)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value.wrappedValue * 100)) percent")
                    .accessibilityHint(accessibilityHint)
                Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            }
        }
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
    @ObservedObject var commandLineTool: CommandLineToolInstaller
    let checkForUpdates: () -> Void
    let quit: () -> Void
    @State private var selection: SettingsDestination

    init(
        audio: NoiseAudioController,
        callActivity: CallActivityController,
        loginItem: LaunchAtLoginController,
        commandLineTool: CommandLineToolInstaller,
        checkForUpdates: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.audio = audio
        self.callActivity = callActivity
        self.loginItem = loginItem
        self.commandLineTool = commandLineTool
        self.checkForUpdates = checkForUpdates
        self.quit = quit
        _selection = State(initialValue: .general)
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
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
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
        .onReceive(NotificationCenter.default.publisher(for: .openNullwaveGeneralSettings)) { _ in
            selection = .general
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
                        .accessibilityHidden(true)
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
                        .accessibilityHint("Stops the preview and returns to the previous sound.")
                    } else {
                        Button("Preview") {
                            audio.togglePreview(of: kind)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Temporarily previews \(kind.displayName) without changing the current sound.")
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
                            .accessibilityHidden(true)
                        Slider(value: Binding(
                            get: { audio.savedVolume(for: kind) },
                            set: { audio.setSavedVolume($0, for: kind) }
                        ), in: 0...1)
                        .accessibilityLabel("Saved volume for \(kind.displayName)")
                        .accessibilityValue("\(Int(audio.savedVolume(for: kind) * 100)) percent")
                        .accessibilityHint(audio.previewKind == kind
                            ? "Adjusts the preview and remembers this volume."
                            : "Remembers this volume without changing the sound currently playing.")
                        Image(systemName: "speaker.wave.3.fill")
                            .accessibilityHidden(true)
                    }
                    Text(audio.previewKind == kind
                        ? "Adjusts this preview and remembers the volume for next time."
                        : "This volume is remembered without changing the sound currently playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if audio.isOtherAudioDuckingEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Volume while other audio is playing").font(.headline)
                            Spacer()
                            Text("\(Int(audio.savedOtherAudioVolume(for: kind) * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Image(systemName: "speaker.fill")
                                .accessibilityHidden(true)
                            Slider(value: Binding(
                                get: { audio.savedOtherAudioVolume(for: kind) },
                                set: { audio.setSavedOtherAudioVolume($0, for: kind) }
                            ), in: 0...1)
                            .accessibilityLabel("Volume for \(kind.displayName) while other audio is playing")
                            .accessibilityValue("\(Int(audio.savedOtherAudioVolume(for: kind) * 100)) percent")
                            .accessibilityHint("Remembers the volume used when another app is playing audio.")
                            Image(systemName: "speaker.wave.3.fill")
                                .accessibilityHidden(true)
                        }
                        Text("Nullwave moves to this level over 200 milliseconds and returns to its normal volume over 400 milliseconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        .accessibilityHidden(true)
                    Text("General")
                        .font(.largeTitle.bold())
                }

                GroupBox("Call Mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Detect headset call mode", isOn: $callActivity.isEnabled)
                            .toggleStyle(.switch)
                            .accessibilityHint("Pauses Nullwave when the same audio device handles input and output, then resumes afterward.")
                        Text(callActivity.isPausedForCall
                            ? "The same device is handling input and output. Nullwave will resume when that route changes."
                            : "When the same device is selected for system input and output, Nullwave pauses until that route changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Other Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Lower volume while other audio plays",
                            isOn: $audio.isOtherAudioDuckingEnabled
                        )
                        .toggleStyle(.switch)
                        .accessibilityHint("Shows a second per-sound volume and uses it while another app is playing audio.")
                        Text("Give every sound a second volume for when another app is playing audio. Nullwave moves smoothly between the two levels.")
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
                        .accessibilityHint("Starts Nullwave automatically after you sign in to this Mac.")

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
                            .accessibilityHint("Checks the Nullwave update feed now.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Command Line") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commandLineTool.isInstalled
                                ? "nullwavectl is installed."
                                : "Control the running app from Terminal.")
                            Text(commandLineTool.destinationPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if let errorMessage = commandLineTool.errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if commandLineTool.isInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Install Command-Line Tool…") {
                                commandLineTool.install()
                            }
                            .accessibilityHint("Installs nullwavectl at \(commandLineTool.destinationPath).")
                        }
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
                        .accessibilityLabel("Nullwave logo")
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
                        .accessibilityHidden(true)
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
                    .accessibilityLabel("Favorite slot \(index + 1)")
                    .accessibilityValue(kind.displayName)
                    .accessibilityHint("Choose the sound shown in this quick-control slot.")
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
