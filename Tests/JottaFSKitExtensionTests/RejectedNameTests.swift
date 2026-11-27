import Foundation
import JottaFSCore
import Testing
@testable import JottaFSKitExtension

// Names Jottacloud cannot store: Finder only shows "error code -50", so the
// extension posts a notification that says why (2026-11-27).

@Suite("Notification for names Jottacloud cannot store")
struct RejectedNameTests {
    private final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(title: String, body: String)] = []
        func add(_ title: String, _ body: String) { lock.withLock { items.append((title, body)) } }
        var all: [(title: String, body: String)] { lock.withLock { items } }
    }

    private func reporter(_ posted: Posted, quietFor: Duration = .seconds(10)) -> RejectedNameReporter {
        RejectedNameReporter(collectFor: .seconds(60), quietFor: quietFor) { title, body in
            posted.add(title, body)
        }
    }

    @Test("one name: the notification names it and the characters")
    func oneName() {
        let text = JottaFSNameNotice.text(for: ["photo?.jpg"])
        #expect(text.title.contains("photo?.jpg"))
        #expect(text.body.contains("?"))
    }

    @Test("a colon shows as a slash, as in Finder")
    func colonAsSlash() {
        #expect(JottaFSNameNotice.text(for: ["a:b.txt"]).title.contains("a/b.txt"))
    }

    @Test("a name that is too long says so")
    func tooLong() {
        let text = JottaFSNameNotice.text(for: [String(repeating: "a", count: 300)])
        #expect(text.body.contains("too long"))
    }

    @Test("several names: a count, three names and how many more")
    func severalNames() {
        let text = JottaFSNameNotice.text(for: ["1?", "2?", "3?", "4?", "5?"])
        #expect(text.title.contains("5"))
        #expect(text.body.contains("“1?”") && text.body.contains("“3?”"))
        #expect(!text.body.contains("“4?”"))
        #expect(text.body.contains("2 more"))
    }

    @Test("names rejected together give one notification")
    func collected() async {
        let posted = Posted()
        let reporter = reporter(posted)
        await reporter.add("a?")
        await reporter.add("b*")
        await reporter.flush()
        #expect(posted.all.count == 1)
        #expect(posted.all.first?.title.contains("2") == true)
    }

    @Test("the same name again soon is not reported twice")
    func repeatedName() async {
        let posted = Posted()
        let reporter = reporter(posted)
        await reporter.add("a?")
        await reporter.add("a?")
        await reporter.flush()
        await reporter.add("a?")
        await reporter.flush()
        #expect(posted.all.count == 1)
        #expect(posted.all.first?.title.contains("a?") == true)
    }

    @Test("the same name is reported again after the quiet time")
    func repeatedLater() async throws {
        let posted = Posted()
        let reporter = reporter(posted, quietFor: .milliseconds(50))
        await reporter.add("a?")
        await reporter.flush()
        try await Task.sleep(for: .milliseconds(100))
        await reporter.add("a?")
        await reporter.flush()
        #expect(posted.all.count == 2)
    }

    @Test("empty, \".\" and \"..\" are not reported")
    func unreportable() async {
        let posted = Posted()
        let reporter = reporter(posted)
        for name in ["", ".", ".."] {
            await reporter.add(name)
        }
        await reporter.flush()
        #expect(posted.all.isEmpty)
    }
}
