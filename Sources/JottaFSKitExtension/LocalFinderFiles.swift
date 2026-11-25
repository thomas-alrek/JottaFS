import Foundation
import JottaFSCore
import OSLog

/// Finder's own files in the mounted location — `.DS_Store` (a folder's view
/// settings) and `._name` (AppleDouble files that hold a file's extended
/// attributes: tags, comments, quarantine…) — kept on this Mac instead of
/// on Jottacloud (docs/write-support-design.md, "Finder's own files").
///
/// They behave like any other file on the volume (create, write, read,
/// truncate, rename, delete), but their contents live in the extension's
/// Application Support folder, in a tree that mirrors the location's folders:
/// `LocalFiles/<location key>/<folder path>/<name>`. That folder lasts across
/// unmounts and restarts. Nothing is uploaded, and such files that are
/// already on Jottacloud stay there but are hidden.
///
/// The kernel keeps a file and its `._` file together: renaming or deleting a
/// file also renames or deletes its `._` file through the volume. Folders
/// are kept in step by the volume (rename and delete move or remove their
/// mirrored folder). What changes elsewhere (jottacloud.com, other devices)
/// is cleaned up when a folder is listed (`prune`).
final class LocalFinderFiles: @unchecked Sendable {
    /// The location's mirrored tree.
    let root: URL
    private let lock = NSLock()
    private let logger = Logger.extension("LocalFiles")

    /// A `._name` file whose file is gone is removed only when it is older
    /// than this, so a file still being created (not listed by Jottacloud
    /// yet) keeps its `._` file.
    static let orphanFileAge: TimeInterval = 60 * 60
    /// A mirrored folder whose folder is gone is removed only when it is
    /// older than this, so putting a folder back from the Trash keeps its
    /// view settings and its files' tags.
    static let orphanFolderAge: TimeInterval = 7 * 24 * 60 * 60

    init(key: String) throws {
        root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "LocalFiles", directoryHint: .isDirectory)
        .appending(path: key, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Whether `name` is one of Finder's own files that stay on this Mac.
    static func isLocalName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(".DS_Store") == .orderedSame
            || (name.hasPrefix("._") && name.count > 2)
    }

    /// The local file or folder for a path in the location ("" is the root).
    func url(_ path: String) -> URL? {
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
            return nil
        }
        return path.isEmpty ? root : root.appending(path: path)
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    // MARK: Listing

    /// The local files directly in the folder at `folder`.
    func entries(inFolder folder: String) -> [JottacloudDirectoryEntry] {
        guard let directory = url(folder) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard Self.isLocalName(name),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else {
                return nil
            }
            return JottacloudDirectoryEntry(
                entry: RemoteEntry(
                    name: name,
                    kind: .file,
                    size: UInt64(values.fileSize ?? 0),
                    modified: values.contentModificationDate
                ),
                role: .localFile(path: Self.join(folder, name))
            )
        }
    }

    /// Removes what no longer matches the folder's items on Jottacloud
    /// (`names`, case-folded): `._name` files whose file is gone and
    /// mirrored folders whose folder is gone, once they are old enough.
    func prune(folder: String, keeping names: Set<String>) {
        guard let directory = url(folder) else {
            return
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let now = Date()
        lock.withLock {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            var removed = 0
            for url in urls {
                let name = url.lastPathComponent
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    continue
                }
                let age = now.timeIntervalSince(values.contentModificationDate ?? now)
                if values.isDirectory == true {
                    guard !names.contains(name.lowercased()), age > Self.orphanFolderAge else {
                        continue
                    }
                } else if name.hasPrefix("._"), name.count > 2 {
                    let owner = String(name.dropFirst(2)).lowercased()
                    guard !names.contains(owner), age > Self.orphanFileAge else {
                        continue
                    }
                } else {
                    // `.DS_Store` belongs to the folder itself.
                    continue
                }
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
            if removed > 0 {
                logger.info("Removed \(removed, privacy: .public) local Finder files whose items are gone.")
            }
        }
    }

    // MARK: Changes

    /// Creates an empty local file (replacing one that exists).
    func create(_ path: String) throws {
        guard let url = url(path) else {
            throw POSIXError(.EINVAL)
        }
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw POSIXError(.EIO)
            }
        }
    }

    /// Stores `source`'s contents as the local file at `path`.
    func copy(_ source: URL, to path: String) throws {
        guard let url = url(path) else {
            throw POSIXError(.EINVAL)
        }
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    /// Moves a local file (or a file from outside, such as the Trash's local
    /// folder) to `path`, replacing what is there.
    func move(_ source: URL, to path: String) throws {
        guard let url = url(path) else {
            throw POSIXError(.EINVAL)
        }
        try lock.withLock {
            guard source != url else {
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: source, to: url)
        }
    }

    /// Deletes a local file (nothing if it is gone).
    func remove(_ path: String) throws {
        guard let url = url(path) else {
            throw POSIXError(.EINVAL)
        }
        try lock.withLock {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            }
        }
    }

    /// Moves a folder's local files (its whole mirrored tree) with the folder.
    func moveFolder(from source: String, to destination: String) {
        guard let from = url(source), let to = url(destination), from != to else {
            return
        }
        lock.withLock {
            guard FileManager.default.fileExists(atPath: from.path) else {
                return
            }
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                logger.error("Could not move a folder's local Finder files (\((error as NSError).code, privacy: .public)).")
            }
        }
    }

    /// Deletes a folder's local files (its whole mirrored tree).
    func removeFolder(_ path: String) {
        guard !path.isEmpty, let url = url(path) else {
            return
        }
        lock.withLock {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
