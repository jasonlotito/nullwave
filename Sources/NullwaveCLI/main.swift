import AppKit
import Foundation

private let bundleIdentifier = "com.jasonlotito.nullwave"
private let notificationName = Notification.Name("com.jasonlotito.nullwave.control")

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("nullwavectl: \(message)\n".utf8))
    exit(code)
}

private func usage() -> Never {
    fail(
        """
        usage:
          nullwavectl play
          nullwavectl stop
          nullwavectl toggle
          nullwavectl volume <0-100>
          nullwavectl other-volume <0-100>
          nullwavectl noise <dark|brown|pink|white|gray|blue|violet|deep|fan|cabin|ocean>
        """,
        code: 64
    )
}

guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
    fail("Nullwave is not running", code: 2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

var userInfo: [String: Any] = ["command": command]

switch command {
case "play", "stop", "toggle":
    guard arguments.count == 1 else { usage() }

case "volume", "other-volume":
    guard arguments.count == 2,
          let percent = Double(arguments[1]),
          (0...100).contains(percent) else {
        fail("\(command) must be a number from 0 through 100", code: 64)
    }
    userInfo["value"] = percent / 100

case "noise":
    let validKinds = ["dark", "brown", "pink", "white", "gray", "blue", "violet", "deep", "fan", "cabin", "ocean"]
    guard arguments.count == 2, validKinds.contains(arguments[1]) else {
        fail("unknown noise; choose dark, brown, pink, white, gray, blue, violet, deep, fan, cabin, or ocean", code: 64)
    }
    userInfo["value"] = arguments[1]

default:
    usage()
}

DistributedNotificationCenter.default().postNotificationName(
    notificationName,
    object: bundleIdentifier,
    userInfo: userInfo,
    deliverImmediately: true
)
