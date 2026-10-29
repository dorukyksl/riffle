import Cocoa

extension Notification.Name {
    /// Posted by a second launch so the running instance shows its settings instead.
    static let riffleShowSettings = Notification.Name("com.dorukyuksel.riffle.showSettings")
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// One Riffle at a time: a lock file in Application Support, held for the life of the process.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Riffle", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

enum Relauncher {
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = arguments(opening: Bundle.main.bundlePath, after: ProcessInfo.processInfo.processIdentifier)
        try? task.run()
        NSApp.terminate(nil)
    }

    /// `/bin/sh` arguments that wait for process `pid` to be gone, and with it the single-instance lock, then open `app`
    /// with `opener`. A process that takes longer than `patience` seconds to quit is waited for no longer: `app` opens
    /// anyway. The app and pid go in as the script's arguments, never into its text.
    static func arguments(opening app: String, after pid: pid_t, opener: String = "/usr/bin/open", patience: TimeInterval = 10) -> [String] {
        let checks = max(Int((patience * 10).rounded()), 0)
        let script = "i=0; while [ \"$i\" -lt \(checks) ] && kill -0 \"$1\" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done; exec \(opener) \"$0\""
        return ["-c", script, app, String(pid)]
    }
}

extension String {
    /// Drops invisible formatting characters (direction marks and the like) some apps put in names and titles. The ones
    /// that hold text together stay: the joiner and non-joiner (emoji such as 👩‍💻, Persian and Indic words) and the tag
    /// characters of flags such as Scotland's.
    var withoutFormatCharacters: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { scalar in
            guard scalar.properties.generalCategory == .format else { return true }
            switch scalar.value {
            case 0x200C, 0x200D, 0xE0020...0xE007F: return true
            default: return false
            }
        }))
    }
}

extension NSWindow {
    /// The WindowServer id, when the window has one that fits a CGWindowID. On macOS 26 some system-owned windows
    /// (FrontBoard scenes) report numbers that don't fit in 32 bits, so never convert `windowNumber` blindly.
    var cgWindowID: CGWindowID? {
        NSWindow.cgWindowID(windowNumber: windowNumber)
    }

    static func cgWindowID(windowNumber number: Int) -> CGWindowID? {
        guard number > 0, let id = CGWindowID(exactly: number) else { return nil }
        return id
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension L {
    /// A duration in milliseconds the way the language writes it: "90 ms", "90 msn", "90毫秒".
    static func milliseconds(_ value: Double, in language: AppLanguage = Prefs.shared.language) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = language.locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: UnitDuration.milliseconds))
    }
}
