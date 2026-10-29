import Foundation

/// A stored setting Riffle couldn't read at launch: it went back to its default, and its value was kept in a file in
/// Recovered. Settings → General tells about it until dismissed.
struct RecoveredSetting: Codable, Equatable {
    var key: String
    var file: String
}

/// The backup made just before every setting was reset or imported, in Backups. Settings → General offers it back until
/// dismissed.
struct PreviousSettings: Codable, Equatable {
    enum Reason: String, Codable {
        case reset, imported
    }

    var file: String
    var reason: Reason
}

/// Where Riffle keeps copies of settings, in Application Support/Riffle: values it couldn't read (Recovered) and the
/// settings that were replaced by a reset or an import (Backups). A folder is made when its first file goes in.
enum SettingsFiles {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Riffle", isDirectory: true)
    }

    static var recovered: URL { folder.appendingPathComponent("Recovered", isDirectory: true) }
    static var backups: URL { folder.appendingPathComponent("Backups", isDirectory: true) }

    /// Backups kept: the oldest go once there are more.
    static let backupsKept = 10

    /// "2026-10-12-143005": sorts by date, and fits in a file name.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Writes `data` as "<name>-<stamp>.json" in `directory`, never over another file. The file's URL, or nil.
    static func write(_ data: Data, name: String, in directory: URL, date: Date = Date()) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.warn("settings: can't make the \(directory.lastPathComponent) folder (\((error as NSError).code))")
            return nil
        }
        let base = "\(name)-\(stamp(date))"
        for attempt in 1...50 {
            let url = directory.appendingPathComponent(attempt == 1 ? "\(base).json" : "\(base)-\(attempt).json")
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                Log.warn("settings: can't write \(url.lastPathComponent) (\((error as NSError).code))")
                return nil
            }
        }
        return nil
    }

    /// A stored value as a file: stored JSON as it is, anything else as JSON or, if it can't be, a property list.
    static func contents(of raw: Any) -> Data? {
        if let data = raw as? Data { return data }
        if let json = SettingsSnapshot.jsonData(raw) { return json }
        return try? PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
    }

    /// Keeps each unreadable value in `directory` as "<key>-<date>.json". What was kept, in settings order; a value that
    /// couldn't be kept is missing (and must stay where it is).
    static func keep(_ unreadable: [String: Any], in directory: URL = recovered, date: Date = Date()) -> [RecoveredSetting] {
        let order = SettingsLoad.keys
        let keys = unreadable.keys.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
        return keys.compactMap { key in
            guard let raw = unreadable[key], let data = contents(of: raw),
                  let url = write(data, name: key, in: directory, date: date) else { return nil }
            Log.warn("settings: couldn't read \(key); it's back to its default, the stored value kept as \(url.lastPathComponent)")
            return RecoveredSetting(key: key, file: url.lastPathComponent)
        }
    }

    /// Deletes all but the newest `kept` backups.
    static func pruneBackups(in directory: URL = backups, keeping kept: Int = backupsKept) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(SettingsArchive.backupName + "-") && $0.hasSuffix(".json") }
            .sorted()
        for file in files.dropLast(kept) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
