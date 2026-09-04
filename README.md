<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Nullwave logo">
</p>

<h1 align="center">Nullwave</h1>

A tiny native noise player for macOS and iOS. It generates audio in real time
and has its own volume control, independent of the system volume setting. Its
lunar-wave icon represents the app's dark sound and low-frequency waves.

## Use

- Left-click the waveform in the menu bar to start or stop playback.
- Right-click it to choose among your three favorite sounds and adjust the current sound's volume.
- Choose **Open Nullwave Settings…** for the complete sound library, descriptions, per-sound volumes, and favorite ordering.
- Enable **Launch at Login** to keep it waiting in the menu bar after signing in.
- Nullwave checks its signed update feed daily; use **Check for Updates…** in
  General Settings whenever you want to check immediately.
- Every sound remembers its normal volume and its volume while other audio is playing; new installs default to 30% for both.
- On macOS, enable **Lower volume while other audio plays** in General to reveal and use the secondary per-sound volume. Nullwave moves down to it over 200 milliseconds and returns to normal over 400 milliseconds.
- **Detect headset call mode** optionally pauses when the same device becomes both the system input and output. It resumes afterward only when Nullwave was previously playing. It does not inspect applications or record microphone audio, and it can be disabled for audio setups that do not follow this pattern.
- Choose **Quit Nullwave** in the settings window to close the app.

### Keyboard access

Nullwave uses standard macOS controls throughout. Sliders adjust with the arrow
keys when focused, and the application menu provides these commands whenever
Nullwave is active:

- **Space** — play or stop from Quick Controls
- **Command-Shift-N** — show Quick Controls
- **Command-Shift-P** — play or stop Nullwave
- **Command-,** — open Settings
- **Command-Q** — quit

Use Control-F2 (or Fn-Control-F2, depending on your keyboard settings) to move
keyboard focus to the macOS menu bar and reach the Nullwave status item.

## Build and run

Requires macOS 15 or newer and Xcode 16 or newer.

```sh
make run
```

This creates an ad-hoc signed app at `dist/Nullwave.app` and opens it. You
can drag that app into `/Applications` if you want to keep it. For development,
you can open `Nullwave.xcodeproj` in Xcode and run the shared `Nullwave` scheme.
The Xcode project references the same source and resource files as SwiftPM, so
the Makefile workflow remains fully supported.

```sh
make xcode-build
make xcode-test
```

The Xcode target supports normal Run, Test, Profile, and Archive workflows.
App Store distribution will additionally require selecting an Apple Developer
team, enabling the App Sandbox and appropriate entitlements, and configuring
the App Store signing/profile settings for the final bundle identifier.

For direct distribution outside the App Store, `make release VERSION=1.1.0`
runs tests, builds, signs, notarizes, staples, packages, updates the signed
Sparkle appcast, commits the release metadata, and publishes the GitHub
release. It expects the
`Developer ID Application: Jason Lotito (47UF97CY9G)` identity and a
`notarytool` Keychain profile named `nullwave-notary`. Override either without
editing the project when necessary:

```sh
make release VERSION=1.1.0 \
  DEVELOPER_IDENTITY="Developer ID Application: Example (TEAMID)" \
  NOTARY_PROFILE="example-notary"
```

The private Sparkle EdDSA key remains in Keychain under the `nullwave` account.
GitHub Actions copies the newest private release asset into the public Pages
deployment, so downloads and in-app updates work without making the source
repository public or committing release binaries.

If you enable **Launch at Login** while running the development copy, the app
offers to install itself as `/Applications/Nullwave.app`, relaunches the
installed copy, and completes login-item registration. It uses a distinct
bundle identifier and will not replace the existing Dark Noise application.
If Nullwave was playing before the move, the installed copy resumes the same
noise type and volume automatically.

## iOS app

The separate native SwiftUI app requires iOS 18 or newer. Open the shared
`Nullwave iOS` scheme in Xcode, or build it for the Simulator from the command
line:

```sh
make ios-build
```

The iOS app includes the full eleven-sound library, up to three configurable
favorites, dual per-sound saved volumes, previews, background playback, and explicit
VoiceOver names, values, and hints. Its playback audio session mixes with
music, podcasts, and video from other apps instead of interrupting them. When
another app plays audio, Nullwave smoothly uses each sound's secondary volume,
then returns to its normal volume afterward. It also handles system audio
interruptions and stops safely if headphones are disconnected.

Nullwave does not register itself as the device's Now Playing app, so the other
media app retains its Lock Screen and Control Center playback controls.

## Command-line control

The build also creates `dist/nullwavectl`. It controls an existing Nullwave
process and never launches the app itself:

```sh
./dist/nullwavectl play
./dist/nullwavectl stop
./dist/nullwavectl toggle
./dist/nullwavectl volume 35
./dist/nullwavectl other-volume 20
./dist/nullwavectl noise brown
```

If Nullwave is installed, the same tool is available inside its bundle at
`/Applications/Nullwave.app/Contents/MacOS/nullwavectl`.

In **Nullwave Settings → General → Command Line**, choose **Install Command-Line
Tool…** to make `nullwavectl` available system-wide. macOS asks for an
administrator password before creating `/usr/local/bin/nullwavectl`.

Developers can perform the same installation with:

```sh
make install-cli
nullwavectl play
```

The installed command is a symlink into `/Applications/Nullwave.app`, so it
continues to work after Nullwave updates itself. The Make target accepts
`NULLWAVE_APP` and `CLI_INSTALL_DIR` overrides when needed.

Available sounds are Dark, Brown, Pink, White, Gray, Blue, Violet, Deep, Fan,
Cabin, and Ocean.

```sh
make test
```

Dark noise does not have one standardized acoustic definition. This app's Dark
setting is a very low-passed, bass-heavy noise intended to sound softer and
deeper than brown noise.
