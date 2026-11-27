import Foundation
import Testing
@testable import JottaFSCore

// 2026-11-27: after installing a new version, macOS kept running the file
// system extension of an Xcode build in DerivedData. The app now warns when
// the extension macOS uses is not its own.

@Suite("Which file system extension macOS uses")
struct ExtensionCheckTests {
    private let own = URL(fileURLWithPath: "/Applications/JottaFS.app/Contents/Extensions/JottaFSKitExtension.appex", isDirectory: true)

    @Test("the app's own extension is fine")
    func ownExtension() {
        #expect(JottaFSExtensionCheck.otherExtension(in: [own], own: own) == nil)
    }

    @Test("a trailing slash or an unresolved path is the same extension")
    func samePathSpelledDifferently() {
        let spelled = URL(fileURLWithPath: "/Applications/../Applications/JottaFS.app/Contents/Extensions/JottaFSKitExtension.appex/")
        #expect(JottaFSExtensionCheck.otherExtension(in: [spelled], own: own) == nil)
    }

    @Test("another copy's extension is reported")
    func otherCopy() {
        let other = URL(fileURLWithPath: "/Users/someone/Library/Developer/Xcode/DerivedData/JottaFS-x/Build/Products/Debug/JottaFS.app/Contents/Extensions/JottaFSKitExtension.appex")
        #expect(JottaFSExtensionCheck.otherExtension(in: [other], own: own) == other)
    }

    @Test("own among several is fine")
    func ownAmongSeveral() {
        let other = URL(fileURLWithPath: "/tmp/JottaFS.app/Contents/Extensions/JottaFSKitExtension.appex")
        #expect(JottaFSExtensionCheck.otherExtension(in: [other, own], own: own) == nil)
    }

    @Test("nothing reported: nothing to warn about")
    func nothingReported() {
        #expect(JottaFSExtensionCheck.otherExtension(in: [], own: own) == nil)
    }

    // A disk that stays mounted across an update keeps the extension that
    // mounted it (2026-11-27: Arkiv still ran a DerivedData build after
    // 1.4.1 was installed). The extension records itself per anchor.

    @Test("a disk served by the app's own extension is fine")
    func servedByOwn() {
        let record = JottaFSStorage.ServingExtension(path: own.path, version: "1.4.2")
        #expect(JottaFSExtensionCheck.isServedBy(own: own, record: record))
    }

    @Test("a disk served by another copy's extension is not")
    func servedByOther() {
        let record = JottaFSStorage.ServingExtension(path: "/Users/someone/Library/Developer/Xcode/DerivedData/JottaFS-x/Build/Products/Debug/JottaFS.app/Contents/Extensions/JottaFSKitExtension.appex", version: "1.0.0")
        #expect(!JottaFSExtensionCheck.isServedBy(own: own, record: record))
    }

    @Test("no record: an extension from before 1.4.2")
    func noRecord() {
        #expect(!JottaFSExtensionCheck.isServedBy(own: own, record: nil))
    }

    @Test("records are saved, read and removed per anchor")
    func recordRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("serving-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchor = JottaFSStorage.anchorName(device: "Jotta", mountpoint: "Archive")
        let record = JottaFSStorage.ServingExtension(path: own.path, version: "1.4.2")
        #expect(JottaFSStorage.servingExtension(anchorName: anchor, directory: directory) == nil)
        try JottaFSStorage.recordServingExtension(record, anchorName: anchor, directory: directory)
        #expect(JottaFSStorage.servingExtension(anchorName: anchor, directory: directory) == record)
        #expect(JottaFSStorage.servingExtension(anchorName: "", directory: directory) == nil)
        JottaFSStorage.removeServingExtension(anchorName: anchor, directory: directory)
        #expect(JottaFSStorage.servingExtension(anchorName: anchor, directory: directory) == nil)
    }

    @Test("an invalid anchor name is never used as a file name")
    func invalidAnchorName() {
        let directory = FileManager.default.temporaryDirectory
        #expect(throws: (any Error).self) {
            try JottaFSStorage.recordServingExtension(.init(path: "/x", version: "1"), anchorName: "../../evil", directory: directory)
        }
    }
}
