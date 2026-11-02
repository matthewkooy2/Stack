#if DEBUG
import Foundation

/// Debug-only timing for the answer-to-coaching path. Writes `prep-timing.log` into the app's Documents folder so a
/// run on a real phone can be read back with `devicectl device copy from`. Excluded from Release builds.
enum PrepTrace {
    private static var origin = Date()

    /// Saves a value as readable JSON in Documents so its real shape can be inspected after a run on a phone.
    static func dump(_ name: String, _ value: JSON) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: dir.appendingPathComponent(name + ".json")) }
    }

    static func mark(_ event: String, restart: Bool = false) {
        if restart { origin = Date() }
        let line = String(format: "%7.2fs  %@\n", Date().timeIntervalSince(origin), event)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("prep-timing.log")
        if restart { try? "".write(to: url, atomically: true, encoding: .utf8) }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
