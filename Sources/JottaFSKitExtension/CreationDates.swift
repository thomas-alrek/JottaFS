import Foundation

/// Creation dates set on items (setattrlist, `utimes` with a birth time),
/// reported back by `attributes(for:)`. Jottacloud keeps no creation date for
/// folders, and listings carry only the modification time, so without this a
/// set creation date was accepted and then reported as something else.
///
/// Safari's download helper depends on it: it marks each `name.download`
/// bundle by setting its creation date and refuses to update or move files
/// out of a bundle whose date differs ("invalid download bundle"), which
/// made every Safari download to a JottaFS disk end with "Cannot move file"
/// (fixed in 1.1.3).
///
/// Kept in memory by path (case-folded like the volume), moved with renames
/// and dropped with deletes; gone after an unmount, when Jottacloud's date
/// is shown again.
final class CreationDates: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: timespec] = [:]

    private static func key(_ path: String) -> String {
        path.lowercased()
    }

    func set(_ date: timespec, for path: String) {
        lock.withLock { dates[Self.key(path)] = date }
    }

    func date(for path: String) -> timespec? {
        lock.withLock { dates[Self.key(path)] }
    }

    /// Moves the dates of an item and everything inside it.
    func move(from oldPath: String, to newPath: String) {
        let old = Self.key(oldPath)
        let new = Self.key(newPath)
        guard old != new else {
            return
        }
        lock.withLock {
            for (key, date) in dates where key == old || key.hasPrefix(old + "/") {
                dates.removeValue(forKey: key)
                dates[new + key.dropFirst(old.count)] = date
            }
        }
    }

    /// Forgets the dates of an item and everything inside it.
    func remove(_ path: String) {
        let removed = Self.key(path)
        lock.withLock {
            dates = dates.filter { $0.key != removed && !$0.key.hasPrefix(removed + "/") }
        }
    }
}
