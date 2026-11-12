#if DEBUG
import Foundation

/// Launch with --ui-fixture. The simulated controller never calls macOS process APIs.
@MainActor
final class DebugFixture: MemorySampling, ProcessSampling, ApplicationInventory, ProcessControlling, Preferences {
    private let firstStart = UInt64(Date.now.timeIntervalSince1970) - 4_800
    private var removed: Set<ProcessID> = []
    private let chrome = "/Applications/Example Browser.app"
    private let terminal = "/Applications/Example Terminal.app"
    var protections: [Protection] = []
    var focus: [String: Date] = [:]
    var notifications = false
    var frontmostPID: Int32? { 701 }

    static func make() -> Store {
        let fixture = DebugFixture()
        fixture.focus["example.browser"] = .now.addingTimeInterval(-2400)
        let store = Store(memory: fixture, processes: fixture, apps: fixture, clock: SystemClock(), preferences: fixture,
                          controller: fixture, policy: ActionPolicy(user: 501, ownPID: 199))
        store.setPressure(.elevated)
        store.start(observeSystem: false)
        return store
    }

    func sampleMemory() async -> HostMemory {
        HostMemory(total: Bytes(16 << 30), occupied: Bytes(15 << 30), compressed: Bytes(4 << 30), swap: Bytes(8 << 30))
    }

    func sampleProcesses() async -> [ProcessRecord]? { rows.filter { !removed.contains($0.id) } }

    func applications() -> [RunningApp] {
        [(Int32(700), "Example Browser", "example.browser", chrome),
         (Int32(701), "Example Terminal", "example.terminal", terminal)].compactMap { pid, name, bundle, path in
            guard let row = rows.first(where: { $0.pid == pid }), !removed.contains(row.id) else { return nil }
            return RunningApp(pid: pid, name: name, bundleID: bundle, bundlePath: path,
                              executable: row.path, launched: row.id.start?.date, regular: true)
        }
    }

    func lookUp(_ pid: Int32) -> Lookup {
        guard let row = rows.first(where: { $0.pid == pid }), !removed.contains(row.id) else { return .gone }
        return .present(row)
    }

    func send(_ operation: ProcessOperation, to target: Target, policy: ActionPolicy,
              protections: [Protection]) -> ActionOutcome? {
        // The simulated worker ignores the normal request; the denied worker never exits.
        if target.row.pid == 706 { return .denied("macOS: Operation not permitted.") }
        if target.row.pid != 704 || operation == .force { removed.insert(target.row.id) }
        return nil
    }

    private var rows: [ProcessRecord] {
        [
            row(700, 1, "\(chrome)/Contents/MacOS/Example Browser", 3 << 30),
            row(701, 1, "\(terminal)/Contents/MacOS/Example Terminal", 70 << 20),
            row(702, 701, "/bin/zsh", 4 << 20, tty: 8),
            row(703, 702, "/opt/example/dev-server", 400 << 20, tty: 8),
            row(704, 703, "/opt/example/FixtureWorker", 190 << 20, tty: 8),
            row(705, 1, "\(chrome)/Contents/Helpers/Example Helper", 80 << 20),
            row(706, 703, "/opt/example/DeniedWorker", nil, tty: 8)
        ]
    }

    private func row(_ pid: Int32, _ parent: Int32, _ path: String, _ bytes: UInt64?, tty: UInt32? = nil) -> ProcessRecord {
        ProcessRecord(id: ProcessID(pid: pid, start: Start(seconds: firstStart + UInt64(pid), microseconds: 0)),
                      name: URL(fileURLWithPath: path).lastPathComponent, path: path, uid: 501, parentPID: parent,
                      terminal: tty, footprint: bytes.map(Bytes.init), resident: nil, cpuTime: nil,
                      diskRead: nil, diskWritten: nil)
    }
}
#endif
