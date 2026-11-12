import XCTest
@testable import Swaplight

@MainActor
final class ActionTests: XCTestCase {
    let policy = ActionPolicy(user: 501, ownPID: 99)
    let clock = SystemClock()

    func testIneligibleTargetsNeverReachAdapter() async {
        let mock = ControlMock()
        let actions = ActionEngine(controller: mock, clock: clock)
        let cases = [
            Target(row: row(7, 1), app: nil, name: "stale", sampledAt: clock.now.advanced(by: .seconds(-9)), ambiguous: false),
            target(row(-1, 1)), target(row(1, 1)), target(row(99, 1)),
            target(row(7, nil)), target(row(8, 1, path: nil)), target(row(9, 1, uid: nil)),
            target(row(8, 1, uid: 502)), target(row(8, 1, path: "/System/Library/example")),
            target(row(7, 1), ambiguous: true)
        ]
        for target in cases {
            let outcome = await actions.perform(.stop, target: target, policy: policy, protections: [])
            guard case .blocked = outcome else { return XCTFail("Expected blocked; got \(outcome)") }
        }
        let rule = Protection(key: .executable("/opt/example/worker"), label: "Worker", bundlePath: nil)
        let protected = await actions.perform(.stop, target: target(row(10, 1)), policy: policy, protections: [rule])
        XCTAssertEqual(protected, .blocked("Marked Keep Running."))
        XCTAssertTrue(mock.sent.isEmpty)
    }

    func testForceRequiresOrdinaryTimeoutForSameIdentityAndIsConsumed() async {
        let mock = ControlMock()
        let actions = ActionEngine(controller: mock, clock: clock, timeout: .zero)
        let selected = target(row(11, 1))
        mock.lookup = .present(selected.row)
        let premature = await actions.perform(.force, target: selected, policy: policy, protections: [])
        guard case .blocked = premature else { return XCTFail("Force was available without an ordinary attempt") }
        let timedOut = await actions.perform(.stop, target: selected, policy: policy, protections: [])
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertTrue(actions.canForce(selected))
        XCTAssertFalse(actions.canForce(target(row(11, 2))))
        mock.lookup = .gone
        let exited = await actions.perform(.force, target: selected, policy: policy, protections: [])
        XCTAssertEqual(exited, .exited)
        XCTAssertFalse(actions.canForce(selected))
        XCTAssertEqual(mock.sent, [.stop, .force])
    }

    func testDistinctGoneReplacedAndDeniedOutcomes() async {
        let mock = ControlMock()
        let actions = ActionEngine(controller: mock, clock: clock)
        let target = target(row(11, 1))
        for outcome in [ActionOutcome.alreadyGone, .denied("Operation not permitted")] {
            mock.rejection = outcome
            let result = await actions.perform(.stop, target: target, policy: policy, protections: [])
            XCTAssertEqual(result, outcome)
        }
        mock.rejection = nil
        mock.lookup = .present(row(11, 2))
        let replaced = await actions.perform(.stop, target: target, policy: policy, protections: [])
        XCTAssertEqual(replaced, .replaced)
    }

    func testDarwinControllerRejectsWrongStartBeforeActionOnOwnChild() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWAPLIGHT_DISPOSABLE_TEST"] == "1",
                          "Opt in through the documented disposable-child scheme.")
        let (child, live) = try await makeChild(ignoreTerm: false)
        defer { if child.isRunning { child.terminate() } }
        let realPolicy = ActionPolicy(user: getuid(), ownPID: getpid())
        let start = try XCTUnwrap(live.id.start)
        let forged = row(live.pid, start.seconds - 1, parent: getpid(), path: live.path, uid: live.uid)
        let engine = ActionEngine(controller: DarwinControl(), clock: clock)
        let rejected = await engine.perform(.stop, target: target(forged), policy: realPolicy, protections: [])
        XCTAssertEqual(rejected, .replaced)
        XCTAssertTrue(child.isRunning)
        let exited = await engine.perform(.stop, target: target(live), policy: realPolicy, protections: [])
        XCTAssertEqual(exited, .exited)
        await Task.detached { child.waitUntilExit() }.value
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    func testDarwinForceAfterTimeoutOnOwnChild() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWAPLIGHT_DISPOSABLE_TEST"] == "1",
                          "Opt in through the documented disposable-child scheme.")
        let (child, live) = try await makeChild(ignoreTerm: true)
        let realPolicy = ActionPolicy(user: getuid(), ownPID: getpid())
        let engine = ActionEngine(controller: DarwinControl(), clock: clock, timeout: .milliseconds(500))
        let timedOut = await engine.perform(.stop, target: target(live), policy: realPolicy, protections: [])
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertTrue(child.isRunning)
        let forced = await engine.perform(.force, target: target(live), policy: realPolicy, protections: [])
        XCTAssertEqual(forced, .exited)
        await Task.detached { child.waitUntilExit() }.value
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    private func makeChild(ignoreTerm: Bool) async throws -> (Process, ProcessRecord) {
        let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("SwaplightDisposableChild")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let executable = copy.resolvingSymlinksInPath()
        let child = Process()
        child.executableURL = executable
        child.environment = ignoreTerm ? ["SWAPLIGHT_IGNORE_TERM": "1"] : [:]
        let ready = Pipe()
        child.standardOutput = ready
        try child.run()
        try ready.fileHandleForWriting.close()
        let marker = await Task.detached {
            let handle = ready.fileHandleForReading
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            return poll(&descriptor, 1, 5_000) > 0 ? handle.readData(ofLength: 1) : Data()
        }.value
        guard marker == Data((ignoreTerm ? "I" : "R").utf8) else {
            if child.isRunning { child.terminate() }
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Disposable child did not report the expected signal disposition."])
        }
        let controller = DarwinControl()
        if case .present(let live) = controller.lookUp(child.processIdentifier) {
            let canonicalPath = live.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let parent = live.parentPID == getpid(), owner = live.uid == getuid()
            let start = live.id.start != nil, executableMatches = canonicalPath == executable.path
            if parent, owner, start, executableMatches { return (child, live) }
            if child.isRunning { child.terminate() }
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Could not verify disposable child (parent: \(parent), owner: \(owner), start: \(start), executable: \(executableMatches))."])
        }
        if child.isRunning { child.terminate() }
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Disposable child did not have readable identity."])
    }

    private func target(_ row: ProcessRecord, ambiguous: Bool = false) -> Target {
        Target(row: row, app: nil, name: row.name, sampledAt: clock.now, ambiguous: ambiguous)
    }
}

@MainActor
private final class ControlMock: ProcessControlling {
    var lookup: Lookup = .gone
    var rejection: ActionOutcome?
    var sent: [ProcessOperation] = []

    func lookUp(_ pid: Int32) -> Lookup { lookup }

    func send(_ operation: ProcessOperation, to target: Target, policy: ActionPolicy,
              protections: [Protection]) -> ActionOutcome? {
        sent.append(operation)
        return rejection
    }
}
