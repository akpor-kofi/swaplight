import XCTest
@testable import Swaplight

@MainActor
final class StoreTests: XCTestCase {
    func testFailedReadingsRetainLastGoodValuesAndDisableActions() async throws {
        let scenario = SampleScenario()
        let key = "SwaplightTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let store = makeStore(scenario, LocalPreferences(defaults))
        store.refresh()
        try await until { store.inventoryIsFresh && store.swap != nil }
        let sampledAt = try XCTUnwrap(store.inventory?.at)
        let savedMemory = try XCTUnwrap(store.memory?.at)
        XCTAssertEqual(store.swap?.value, Bytes(0))

        scenario.failed = true
        store.refresh()
        try await until { store.inventoryFailed && store.memoryFailed && store.swapFailed }
        XCTAssertEqual(store.inventory?.at, sampledAt)
        XCTAssertEqual(store.memory?.at, savedMemory)
        XCTAssertEqual(store.swap?.value, Bytes(0))
        XCTAssertTrue(store.memoryIsStale)
        XCTAssertTrue(store.swapIsStale)
        XCTAssertFalse(store.inventoryIsFresh)
        let target = try XCTUnwrap(store.target(for: scenario.record))
        XCTAssertNotNil(store.issue(target))
        store.propose(.stop, target: target)
        XCTAssertNil(store.confirmation)
        XCTAssertEqual(scenario.sendCount, 0)
    }

    func testFocusSurvivesStoreRecreationAndClearsSeparatelyFromProtection() async throws {
        let key = "SwaplightTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let scenario = SampleScenario()
        let prefs = LocalPreferences(defaults)
        let first = makeStore(scenario, prefs)
        let observed = app(row(55, 1, path: "/Applications/Example.app/Contents/MacOS/Example"))
        first.observe(observed)
        let rule = try XCTUnwrap(observed.protection)
        first.toggleProtection(rule)

        let reloaded = makeStore(scenario, LocalPreferences(defaults))
        XCTAssertNotNil(reloaded.focus["test.Example"])
        XCTAssertEqual(reloaded.protections.map(\.key), [rule.key])
        reloaded.clearFocus()
        let after = makeStore(scenario, LocalPreferences(defaults))
        XCTAssertTrue(after.focus.isEmpty)
        XCTAssertEqual(after.protections.map(\.key), [rule.key])
    }

    func testPossibleRespawnIsReportedWithoutSendingAnotherRequest() async throws {
        let key = "SwaplightTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let scenario = SampleScenario()
        scenario.respawn = true
        let store = makeStore(scenario, LocalPreferences(defaults))
        store.refresh()
        try await until { store.inventoryIsFresh }
        let target = try XCTUnwrap(store.target(for: scenario.record))
        store.propose(.stop, target: target)
        let confirmation = try XCTUnwrap(store.confirmation)
        await store.confirm(confirmation)
        try await until { store.outcome?.replacement == true }
        XCTAssertEqual(store.outcome?.outcome, .exited)
        XCTAssertEqual(scenario.sendCount, 1)
    }

    func testActiveFootprintSurvivesSwaplightFocusAndRejectsReusedPID() async throws {
        let key = "SwaplightTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let scenario = SampleScenario()
        let path = "/Applications/Example.app/Contents/MacOS/Example"
        let active = row(55, 1, path: path, bytes: 512 << 20)
        scenario.appRecords = [active]
        scenario.frontmostPID = active.pid
        let store = makeStore(scenario, LocalPreferences(defaults))
        store.refresh()
        try await until { store.activeApp?.id == active.id }
        XCTAssertEqual(store.activeApp?.footprint.known, active.footprint)
        XCTAssertFalse(store.candidates.contains { $0.id == active.id })

        scenario.frontmostPID = 999
        let previous = store.inventory?.at
        store.refresh()
        try await until { store.inventory?.at != previous }
        XCTAssertEqual(store.frontmost, 999)
        XCTAssertEqual(store.activeApp?.id, active.id)
        XCTAssertFalse(store.candidates.contains { $0.id == active.id })

        let replacement = row(active.pid, 2, path: path)
        scenario.appRecords = [replacement]
        store.refresh()
        try await until { store.inventory?.value.regularAppsByPID[active.pid]?.id == replacement.id }
        XCTAssertNil(store.activeApp)
    }

    private func makeStore(_ scenario: SampleScenario, _ prefs: LocalPreferences) -> Store {
        Store(memory: scenario, processes: scenario, apps: scenario, clock: SystemClock(), preferences: prefs,
              controller: scenario, policy: ActionPolicy(user: 501, ownPID: 999))
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = SystemClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate() && clock.now < deadline { try await clock.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Expected the sampler to finish")
    }
}

@MainActor
private final class SampleScenario: MemorySampling, ProcessSampling, ApplicationInventory, ProcessControlling {
    var failed = false
    var sendCount = 0
    var respawn = false
    private var successor: ProcessRecord?
    private let parent = row(42, 1, path: "/opt/example/supervisor")
    let record = row(100, 2, parent: 42)
    var frontmostPID: Int32? = 999
    var appRecords: [ProcessRecord] = []
    func applications() -> [RunningApp] { appRecords.map(app) }

    func sampleMemory() async -> HostMemory {
        HostMemory(total: Bytes(16 << 30), occupied: failed ? nil : Bytes(4 << 30),
                   compressed: failed ? nil : Bytes(512 << 20), swap: failed ? nil : Bytes(0))
    }
    func sampleProcesses() async -> [ProcessRecord]? { failed ? nil : [parent, successor ?? record] + appRecords }
    func lookUp(_ pid: Int32) -> Lookup { successor == nil ? .present(record) : .gone }
    func send(_ operation: ProcessOperation, to target: Target, policy: ActionPolicy,
              protections: [Protection]) -> ActionOutcome? {
        sendCount += 1
        if respawn {
            successor = row(101, UInt64(Date.now.timeIntervalSince1970) + 1, parent: parent.pid)
        }
        return nil
    }
}
