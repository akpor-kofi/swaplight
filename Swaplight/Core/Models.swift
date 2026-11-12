import Foundation

struct Bytes: Comparable, Sendable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    var formatted: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
}

typealias Tick = ContinuousClock.Instant

struct FocusObservation: Sendable {
    let date: Date
    let at: Tick
}

protocol SampleClock: Sendable {
    var now: Tick { get }
    var date: Date { get }
    func sleep(for duration: Duration) async throws
}

struct SystemClock: SampleClock {
    private let clock = ContinuousClock()
    var now: Tick { clock.now }
    var date: Date { .now }
    func sleep(for duration: Duration) async throws { try await clock.sleep(for: duration) }
}

struct Reading<Value: Sendable>: Sendable {
    let value: Value
    let at: Tick
    let date: Date

    func fresh(at now: Tick, within limit: Duration) -> Bool { at.duration(to: now) <= limit }
}

enum Pressure: String, Sendable {
    case unknown = "Unknown", normal = "Normal", elevated = "Elevated", critical = "Critical"
    var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .normal: "checkmark.circle"
        case .elevated: "exclamationmark.circle"
        case .critical: "exclamationmark.triangle.fill"
        }
    }
}

struct HostMemory: Sendable {
    let total: Bytes
    let occupied: Bytes?
    let compressed: Bytes?
    let swap: Bytes?
}

protocol MemorySampling: Sendable {
    func sampleMemory() async -> HostMemory
}

struct Start: Hashable, Comparable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
    static func < (a: Self, b: Self) -> Bool { (a.seconds, a.microseconds) < (b.seconds, b.microseconds) }
    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000) }
}

struct ProcessID: Hashable, Sendable {
    let pid: Int32
    let start: Start?
}

struct ProcessRecord: Identifiable, Sendable {
    let id: ProcessID
    let name: String
    let path: String?
    let uid: UInt32?
    let parentPID: Int32?
    let terminal: UInt32?
    let footprint: Bytes?
    let resident: Bytes?
    let cpuTime: UInt64?
    let diskRead: UInt64?
    let diskWritten: UInt64?
    var pid: Int32 { id.pid }

    var isShell: Bool {
        guard let path, let terminal, terminal != .max, terminal != 0 else { return false }
        return ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/ksh", "/bin/csh", "/bin/tcsh"].contains(path)
            || (["fish", "zsh", "bash", "nu"].contains(URL(fileURLWithPath: path).lastPathComponent)
                && (path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")))
    }
}

struct RunningApp: Sendable {
    let pid: Int32
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let executable: String?
    let launched: Date?
    let regular: Bool

    func matches(_ process: ProcessRecord) -> Bool {
        guard pid == process.pid, let executable, executable == process.path,
              let launched, let start = process.id.start else { return false }
        return abs(launched.timeIntervalSince(start.date)) < 1
    }

    var protection: Protection? {
        guard let bundleID, let bundlePath else { return nil }
        return Protection(key: .app(bundleID), label: name, bundlePath: bundlePath)
    }
}

protocol ProcessSampling: Sendable {
    func sampleProcesses() async -> [ProcessRecord]?
}

@MainActor
protocol ApplicationInventory {
    func applications() -> [RunningApp]
    var frontmostPID: Int32? { get }
}

struct Activity: Sendable {
    let cpuPercent: Double?
    let diskBytes: Bytes?
    let seconds: Double

    init?(now: ProcessRecord, previous: ProcessRecord?, elapsed: Duration) {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard let previous, now.id == previous.id, now.id.start != nil, seconds > 0, seconds <= 15 else { return nil }
        func delta(_ current: UInt64?, _ previous: UInt64?) -> UInt64? {
            guard let current, let previous, current >= previous else { return nil }
            return current - previous
        }
        self.seconds = seconds
        cpuPercent = delta(now.cpuTime, previous.cpuTime).map { Double($0) / (seconds * 1e9) * 100 }
        if let reads = delta(now.diskRead, previous.diskRead), let writes = delta(now.diskWritten, previous.diskWritten) {
            diskBytes = Bytes(reads + writes)
        } else {
            diskBytes = nil
        }
    }
}

struct Footprint: Sendable {
    let known: Bytes?
    let unavailable: Int
    init(_ records: [ProcessRecord]) {
        let values = records.compactMap(\.footprint)
        known = values.isEmpty ? nil : Bytes(values.reduce(0) { $0 + $1.value })
        unavailable = records.count - values.count
    }
    var formatted: String {
        guard let known else { return "Unavailable" }
        return unavailable == 0 ? known.formatted : "\(known.formatted) known"
    }
}

enum ProtectionKey: Codable, Hashable, Sendable {
    case app(String)
    case executable(String)
}

struct Protection: Codable, Identifiable, Sendable {
    let key: ProtectionKey
    let label: String
    let bundlePath: String?
    var id: ProtectionKey { key }
}
