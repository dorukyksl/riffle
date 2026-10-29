// Resolves a classic alias record with macOS's own code and prints the path it names: the check Scripts/make-dmg.sh
// runs on the alias that points the disk image's window at its background picture.
//
//   swift Scripts/check-alias.swift <file holding the alias record>
import Foundation

let record = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, record as CFData)?.takeRetainedValue() else {
    FileHandle.standardError.write("✗ not an alias record macOS can read\n".data(using: .utf8)!)
    exit(1)
}
var stale = false
do {
    let url = try URL(resolvingBookmarkData: bookmark as Data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    print(url.path)
} catch {
    FileHandle.standardError.write("✗ the alias doesn't resolve: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
