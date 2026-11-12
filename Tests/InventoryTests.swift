import XCTest
@testable import Swaplight

final class InventoryTests: XCTestCase {
    func testObservedTreeAndAppAttributionAreSeparate() {
        let terminal = row(10, 10, path: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let browser = row(20, 20, path: "/Applications/Browser.app/Contents/MacOS/Browser")
        let browserChild = row(21, 21, parent: 20, path: "/Applications/Browser.app/Contents/Helpers/Helper")
        let detached = row(22, 22, parent: 1, path: "/Applications/Browser.app/Contents/Helpers/Detached", bytes: nil)
        let shell = row(11, 11, parent: 10, path: "/bin/zsh", tty: 6)
        let job = row(12, 12, parent: 11, tty: 6)
        let worker = row(13, 13, parent: 12)
        let vanishedParent = row(14, 14, parent: 99)
        let impossibleParent = row(15, 9, parent: 10)
        let conflict = row(23, 23, parent: 10, path: "/Applications/Browser.app/Contents/Helpers/Conflict")
        let lookalike = row(24, 24, path: "/elsewhere/Browser")
        let inventory = Inventory(processes: [terminal, browser, browserChild, detached, shell, job, worker,
                                              vanishedParent, impossibleParent, conflict, lookalike, detached],
                                  running: [app(terminal), app(browser)], prior: nil, at: SystemClock().now)
        XCTAssertEqual(inventory.parents[worker.id], job.id)
        XCTAssertEqual(inventory.parents[shell.id], terminal.id)
        XCTAssertEqual(inventory.terminalJobs[job.id], job.id)
        XCTAssertEqual(inventory.terminalJobs[worker.id], job.id)
        for item in [job, worker, vanishedParent, impossibleParent, conflict, lookalike] {
            XCTAssertNil(inventory.attribution[item.id])
        }
        XCTAssertNil(inventory.parents[impossibleParent.id])
        XCTAssertNil(inventory.parents[vanishedParent.id])
        XCTAssertTrue(inventory.ambiguous.contains(conflict.id))
        XCTAssertEqual(inventory.evidence[browserChild.id], .both)
        XCTAssertEqual(inventory.evidence[detached.id], .bundle)
        let group = inventory.apps.first { $0.id == browser.id }
        XCTAssertEqual(group?.count, 3)
        XCTAssertEqual(group?.footprint.known, Bytes(800 << 20))
        XCTAssertEqual(group?.footprint.unavailable, 1)
        XCTAssertEqual(inventory.apps.flatMap(\.members).count, Set(inventory.apps.flatMap(\.members).map(\.id)).count)
    }

    func testReviewListsHideSystemAndMissingFootprintsWithoutAMemoryCutoff() {
        let policy = ActionPolicy(user: 501, ownPID: 99)
        let small = row(10, 1, bytes: 1_024)
        let unreadable = row(11, 2, bytes: nil)
        let system = row(12, 3, path: "/System/Library/Example", bytes: 30 << 20)
        let otherUser = row(13, 4, uid: 502, bytes: 30 << 20)
        let appWithUnknownFootprint = row(14, 5, path: "/Applications/Example.app/Contents/MacOS/Example", bytes: nil)
        let inventory = Inventory(processes: [small, unreadable, system, otherUser, appWithUnknownFootprint],
                                  running: [app(appWithUnknownFootprint)], prior: nil, at: SystemClock().now)
        XCTAssertEqual(inventory.records.values.filter { inventory.isReviewable($0, policy: policy) }.map(\.id), [small.id])
        XCTAssertTrue(inventory.apps.filter { inventory.isReviewable($0, policy: policy) }.isEmpty)
        XCTAssertTrue(inventory.matches(small, query: "10"))
        XCTAssertFalse(inventory.matches(small, query: "1"))
    }

    func testReusedPIDAndPartialDataDontInheritIdentityOrActivity() {
        let start = SystemClock().now
        let original = row(9, 1, bytes: 90, cpu: 1_000)
        let old = Inventory(processes: [original], running: [], prior: nil, at: start)
        let reused = row(9, 2, bytes: nil, cpu: 4_000)
        let next = Inventory(processes: [reused], running: [],
                             prior: Reading(value: old, at: start, date: .now), at: start.advanced(by: .seconds(2)))
        XCTAssertNil(next.records[original.id])
        XCTAssertNil(next.activity[reused.id])
        XCTAssertNil(next.records[reused.id]?.footprint)
        XCTAssertNil(Footprint([reused]).known)

        let same = row(9, 1, bytes: 90, cpu: 2_000_001_000)
        let measured = Activity(now: same, previous: original, elapsed: .seconds(2))
        XCTAssertEqual(measured?.cpuPercent, 100)
        XCTAssertNil(Activity(now: original, previous: same, elapsed: .seconds(2))?.cpuPercent)
        XCTAssertNil(Activity(now: same, previous: original, elapsed: .seconds(20)))
    }

    func testRecommendationsKeepUnknownFocusDistinctAndExcludeProtectedAndFrontmost() {
        let one = row(11, 11, path: "/Applications/One.app/Contents/MacOS/One")
        let two = row(12, 12, path: "/Applications/Two.app/Contents/MacOS/Two", bytes: 850 << 20)
        let three = row(13, 13, path: "/Applications/Three.app/Contents/MacOS/Three")
        let four = row(14, 14, path: "/Applications/Four.app/Contents/MacOS/Four")
        let appList = [one, two, three, four].map(app)
        let now = SystemClock().now
        let inventory = Inventory(processes: [one, two, three, four], running: appList, prior: nil, at: now)
        let lastFocus = FocusObservation(date: .now, at: now)
        let items = Recommendations.candidates(in: inventory, frontmost: four.pid,
            policy: ActionPolicy(user: 501, ownPID: 99), protections: [appList[2].protection!],
            focus: ["test.One": lastFocus], now: now)
        XCTAssertEqual(items.map(\.id), [two.id, one.id])
        XCTAssertTrue(items[0].reason.contains("focus not observed"))
    }

    func testRecommendationsCompareAppAndJobFootprintsWithBoundedFocusWeight() {
        let recent = row(11, 11, path: "/Applications/Recent.app/Contents/MacOS/Recent", bytes: 2_000 << 20)
        let earlier = row(12, 12, path: "/Applications/Earlier.app/Contents/MacOS/Earlier", bytes: 1_800 << 20)
        let oldest = row(13, 13, path: "/Applications/Oldest.app/Contents/MacOS/Oldest", bytes: 1_700 << 20)
        let shell = row(20, 20, path: "/bin/zsh", tty: 6)
        let job = row(21, 21, parent: shell.pid, bytes: 700 << 20, tty: 6)
        let worker = row(22, 22, parent: job.pid, bytes: 1_500 << 20)
        let now = SystemClock().now
        let inventory = Inventory(processes: [recent, earlier, oldest, shell, job, worker],
                                  running: [recent, earlier, oldest].map(app), prior: nil, at: now)
        let focus = [
            "test.Recent": FocusObservation(date: .now, at: now),
            "test.Earlier": FocusObservation(date: .now, at: now.advanced(by: .seconds(-3_600))),
            "test.Oldest": FocusObservation(date: .now, at: now.advanced(by: .seconds(-28_800)))
        ]

        let items = Recommendations.candidates(in: inventory, frontmost: 99,
            policy: ActionPolicy(user: 501, ownPID: 99), protections: [], focus: focus, now: now)

        XCTAssertEqual(items.map(\.id), [job.id, oldest.id, earlier.id, recent.id])
        XCTAssertEqual(items.map(\.footprint.known), [Bytes(2_200 << 20), oldest.footprint, earlier.footprint, recent.footprint])
    }
}

func row(_ pid: Int32, _ start: UInt64?, parent: Int32 = 1, path: String? = "/opt/example/worker",
         uid: UInt32? = 501, bytes: UInt64? = 400 << 20, cpu: UInt64? = nil, tty: UInt32? = nil) -> ProcessRecord {
    ProcessRecord(id: ProcessID(pid: pid, start: start.map { Start(seconds: $0, microseconds: 0) }),
                  name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown",
                  path: path, uid: uid, parentPID: parent, terminal: tty, footprint: bytes.map(Bytes.init),
                  resident: nil, cpuTime: cpu, diskRead: nil, diskWritten: nil)
}

func app(_ row: ProcessRecord) -> RunningApp {
    let root = row.path?.components(separatedBy: "/Contents/").first
    return RunningApp(pid: row.pid, name: row.name, bundleID: "test.\(row.name)", bundlePath: root,
                      executable: row.path, launched: row.id.start?.date, regular: true)
}
