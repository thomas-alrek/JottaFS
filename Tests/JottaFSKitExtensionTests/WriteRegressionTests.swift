import Foundation
import JottaFSCore
import Testing
@testable import JottaFSKitExtension

// Regression tests for the extension's write path. They run with
// `swift test` (`make check`), which `scripts/release.sh` runs before it
// builds a release; a failure stops the release.

private let volume = JottacloudRemoteVolume(device: "Jotta", mountpoint: "Archive")

private func fileEntry(_ name: String, size: UInt64, md5: String? = nil) -> JottacloudDirectoryEntry {
    JottacloudDirectoryEntry(
        entry: RemoteEntry(name: name, kind: .file, size: size, modified: Date(timeIntervalSince1970: 0), md5: md5),
        role: .remote(volume, path: name)
    )
}

/// A staging area in its own folder, removed afterwards.
private func withStaging(_ body: (StagingArea) async throws -> Void) async throws {
    let key = "tests-\(UUID().uuidString)"
    let staging = try StagingArea(key: key)
    defer {
        let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        if let folder = caches?.appendingPathComponent("Staging/\(key)", isDirectory: true) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    try await body(staging)
}

@Suite("1.1.2 regression: files showed 0 bytes after upload")
struct ZeroByteRegression {
    /// The bug: `create` records the new file with size 0; a lookup or
    /// listing during the upload (Finder relists the folder when it writes
    /// `._file` and `.DS_Store`) replaced the item's written size with that
    /// 0, and the upload then recorded the 0. The listing must not change a
    /// staged file's size.
    @Test func listingDuringUploadKeepsTheWrittenSize() async throws {
        try await withStaging { staging in
            let store = ItemStore(rootRole: .mountpoint(volume), isStaged: { staging.file($0) != nil })
            let root = store.rootItem()
            let item = try store.child(of: root, entry: fileEntry("photo.jpg", size: 0))
            _ = try await staging.stage(item.identifier) { _ in }
            let size = try staging.write(Data(repeating: 7, count: 1234), to: item.identifier, at: 0)
            // What `writeData` does after each write.
            item.entry = RemoteEntry(name: "photo.jpg", kind: .file, size: size, modified: Date())

            // A listing with the overlay from `create` (size 0).
            let again = try store.child(of: root, entry: fileEntry("photo.jpg", size: 0))

            #expect(again === item)
            #expect(item.entry.size == 1234)
        }
    }

    /// Without a local copy the listing is the truth (a change made on
    /// jottacloud.com or another device must show up).
    @Test func listingUpdatesAFileWithoutLocalCopy() throws {
        let store = ItemStore(rootRole: .mountpoint(volume), isStaged: { _ in false })
        let root = store.rootItem()
        let item = try store.child(of: root, entry: fileEntry("notes.txt", size: 10))
        _ = try store.child(of: root, entry: fileEntry("notes.txt", size: 99, md5: "abc"))
        #expect(item.entry.size == 99)
        #expect(item.entry.md5 == "abc")
    }

    /// After an upload the item takes the size and MD5 that Jottacloud
    /// verified, whatever (possibly stale) entry it had.
    @Test func uploadedEntryIsWhatJottacloudVerified() {
        let stale = RemoteEntry(name: "Photo.JPG", kind: .file, size: 0, modified: nil)
        let verified = RemoteEntry(name: "photo.jpg", kind: .file, size: 1234, modified: nil, md5: "d41d8")
        let written = Date(timeIntervalSince1970: 1_800_000_000)

        let entry = ItemStore.uploadedEntry(stale, verified: verified, modified: written)

        #expect(entry.size == 1234)
        #expect(entry.md5 == "d41d8")
        #expect(entry.name == "Photo.JPG")
        #expect(entry.modified == written)
    }
}

@Suite("Failed uploads must not freeze Finder")
struct FailedUploadRegression {
    /// Sync and reclaim leave a file alone for a while after its upload
    /// failed, with a pause that doubles up to a limit.
    @Test func failedUploadsBackOff() async throws {
        try await withStaging { staging in
            let id: UInt64 = 42
            let now = Date()
            #expect(!staging.isBackingOff(id, now: now))

            staging.uploadFailed(id, now: now)
            #expect(staging.isBackingOff(id, now: now.addingTimeInterval(29)))
            #expect(!staging.isBackingOff(id, now: now.addingTimeInterval(31)))

            staging.uploadFailed(id, now: now)
            #expect(staging.isBackingOff(id, now: now.addingTimeInterval(59)))
            #expect(!staging.isBackingOff(id, now: now.addingTimeInterval(61)))

            for _ in 0..<20 {
                staging.uploadFailed(id, now: now)
            }
            #expect(!staging.isBackingOff(id, now: now.addingTimeInterval(StagingArea.maximumBackoff + 1)))

            staging.uploadSucceeded(id)
            #expect(!staging.isBackingOff(id, now: now))
        }
    }

    /// Deleting a file stops its running upload instead of waiting for it
    /// (an upload over a poor connection can take many minutes).
    @Test func deleteStopsARunningUpload() async throws {
        try await withStaging { staging in
            let id: UInt64 = 7
            let upload = Task {
                try await staging.serializeUpload(id) {
                    try await Task.sleep(for: .seconds(600))
                }
            }
            // Let the upload start.
            for _ in 0..<100 where !staging.isUploading(id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(staging.isUploading(id))

            let started = Date()
            staging.cancelUpload(id)
            await staging.waitForUpload(id)

            #expect(Date().timeIntervalSince(started) < 5)
            await #expect(throws: CancellationError.self) {
                try await upload.value
            }
        }
    }
}

@Suite("1.1.3 test build: the extension livelocked after a large upload")
struct UploadWaitersRegression {
    /// The bug: callers waiting for a running upload (sync, reclaim,
    /// delete) looped on "is an upload registered? then await it". The
    /// finished upload stayed registered until the task that started it
    /// ran again, and awaiting a finished task does not give up the thread,
    /// so enough waiters took every thread of the pool and that task never
    /// ran: the extension hung with all threads busy (seen 2026-11-26 after
    /// copying a 1 GB file). Waiters must end once the upload ends.
    @Test func manyWaitersEndWhenTheUploadEnds() async throws {
        try await withStaging { staging in
            let id: UInt64 = 9
            let finished = DoneFlag()
            // A livelock also starves this test's own tasks, so a plain
            // thread watches the clock and fails the run loudly.
            let watchdog = Thread {
                Thread.sleep(forTimeInterval: 30)
                if !finished.isSet {
                    fatalError("Livelock: waiters for a finished upload never ended (StagingArea.serializeUpload/waitForUpload).")
                }
            }
            watchdog.start()

            let upload = Task {
                try await staging.serializeUpload(id) {
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            for _ in 0..<100 where !staging.isUploading(id) {
                try await Task.sleep(for: .milliseconds(5))
            }
            // Far more waiters than the pool has threads.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<(ProcessInfo.processInfo.activeProcessorCount * 8) {
                    group.addTask {
                        if index.isMultiple(of: 2) {
                            try await staging.serializeUpload(id) {}
                        } else {
                            await staging.waitForUpload(id)
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await upload.value
            finished.set()
            #expect(!staging.isUploading(id))
        }
    }
}

private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Safari downloads: 'Cannot move file'")
struct CreationDateRegression {
    /// The bug: Safari's download helper marks a `name.download` bundle by
    /// setting its creation date, and later refuses to update or move files
    /// out of a bundle whose creation date differs ("invalid download
    /// bundle"). JottaFS accepted the date but reported another one, so every
    /// Safari download to a JottaFS disk ended with "Cannot move file". A set
    /// creation date must be reported back, also after renames.
    @Test func setCreationDateIsReportedBack() {
        let dates = CreationDates()
        let marker = timespec(tv_sec: 443_779_200, tv_nsec: 0)
        dates.set(marker, for: "Downloads/file.zip.download")

        #expect(dates.date(for: "Downloads/file.zip.download")?.tv_sec == marker.tv_sec)
        // Case-insensitive like the volume.
        #expect(dates.date(for: "downloads/FILE.zip.download")?.tv_sec == marker.tv_sec)
        #expect(dates.date(for: "Downloads/other") == nil)
    }

    @Test func creationDatesFollowRenamesAndDeletes() {
        let dates = CreationDates()
        let date = timespec(tv_sec: 1_000, tv_nsec: 0)
        dates.set(date, for: "a/folder")
        dates.set(date, for: "a/folder/inner.txt")
        dates.set(date, for: "a/folder-other")

        dates.move(from: "a/folder", to: "b/renamed")
        #expect(dates.date(for: "a/folder") == nil)
        #expect(dates.date(for: "b/renamed")?.tv_sec == 1_000)
        #expect(dates.date(for: "b/renamed/inner.txt")?.tv_sec == 1_000)
        // A sibling that only shares the prefix stays where it is.
        #expect(dates.date(for: "a/folder-other")?.tv_sec == 1_000)

        dates.remove("b/renamed")
        #expect(dates.date(for: "b/renamed") == nil)
        #expect(dates.date(for: "b/renamed/inner.txt") == nil)
        #expect(dates.date(for: "a/folder-other") != nil)
    }
}

@Suite("Apps and scripts on a Jottacloud disk must run")
struct ExecutePermissionRegression {
    /// The bug: every file reported mode 0644 (Jottacloud keeps no
    /// permissions), so macOS refused to run programs on the disk:
    /// FileZilla.app in the root of a Jottacloud disk failed with
    /// "access(…/Contents/MacOS/filezilla, X_OK) failed with errno 13".
    /// Files in the location must carry the execute bits, like on FAT and
    /// exFAT disks.
    @Test func filesInTheLocationAreExecutable() {
        let mode = JottaFSVolume.permissions(kind: .file, role: .remote(volume, path: "FileZilla.app/Contents/MacOS/filezilla"), writable: true)
        #expect(mode == 0o755)
        #expect(mode & 0o111 == 0o111)
    }

    @Test func otherItemsKeepTheirModes() {
        // Folders, Finder's own files, read-only items and the Trash.
        #expect(JottaFSVolume.permissions(kind: .directory, role: .remote(volume, path: "folder"), writable: true) == 0o755)
        #expect(JottaFSVolume.permissions(kind: .file, role: .localFile(path: ".DS_Store"), writable: true) == 0o644)
        #expect(JottaFSVolume.permissions(kind: .file, role: .volumeIcon, writable: false) == 0o444)
        #expect(JottaFSVolume.permissions(kind: .directory, role: .trashes, writable: true) == 0o1333)
        #expect(JottaFSVolume.permissions(kind: .directory, role: .userTrash, writable: true) == 0o700)
    }
}
