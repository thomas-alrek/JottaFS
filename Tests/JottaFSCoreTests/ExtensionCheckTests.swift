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
}
