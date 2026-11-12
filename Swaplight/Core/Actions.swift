import Foundation

struct ActionPolicy: Sendable {
    let user: UInt32
    let ownPID: Int32
    static let protectedBundleIDs: Set<String> = ["com.apple.finder", "com.apple.dock",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.loginwindow", "com.apple.WindowManager",
        "com.apple.systempreferences", "com.apple.SecurityAgent", "com.nukodes.swaplight"]

    func issue(for row: ProcessRecord, app: RunningApp?, ancestry: [ProcessRecord], ambiguous: Bool,
               protections: [Protection]) -> String? {
        guard row.pid > 1, row.pid != ownPID, user != 0 else { return "System or Swaplight process." }
        guard row.id.start != nil, let path = row.path, path.hasPrefix("/"), let owner = row.uid else {
            return "Process identity, owner or executable is unavailable."
        }
        guard owner == user else { return "Owned by another user or macOS." }
        guard !ambiguous else { return "App attribution is uncertain." }
        if let app {
            guard app.matches(row), app.regular, let root = app.bundlePath,
                  root.hasSuffix(".app"), path.hasPrefix(root + "/") else { return "App identity could not be verified." }
            if let id = app.bundleID, Self.protectedBundleIDs.contains(id) { return "Protected macOS or Swaplight app." }
        }
        let systemRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/PrivilegedHelperTools/"]
        let localTool = path.hasPrefix("/usr/local/")
        let systemGUI = app != nil && (path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/System/Volumes/Preboot/Cryptexes/App/System/Applications/"))
        guard localTool || systemGUI || !systemRoots.contains(where: path.hasPrefix) else {
            return "Protected macOS executable."
        }
        guard !isProtected(row: row, app: app, ancestry: ancestry, protections: protections) else {
            return "Marked Keep Running."
        }
        return nil
    }

    func isProtected(row: ProcessRecord, app: RunningApp?, ancestry: [ProcessRecord],
                     protections: [Protection]) -> Bool {
        protections.contains { rule in
            switch rule.key {
            case .app(let id):
                if app?.bundleID == id { return true }
                guard let prefix = rule.bundlePath.map({ $0 + "/" }) else { return false }
                return ([row] + ancestry).contains { $0.path?.hasPrefix(prefix) == true }
            case .executable(let path):
                return row.path == path
            }
        }
    }
}

enum ProcessOperation: String, Sendable {
    case quit = "Quit App"
    case stop = "Stop Process"
    case force = "Force Stop"
}

struct Target: Sendable {
    let row: ProcessRecord
    let app: RunningApp?
    let name: String
    let sampledAt: Tick
    let ambiguous: Bool

    func sameIdentity(as other: Self) -> Bool {
        row.id == other.row.id && row.uid == other.row.uid && row.path == other.row.path
            && (app == nil) == (other.app == nil)
            && app?.bundleID == other.app?.bundleID && app?.bundlePath == other.app?.bundlePath
    }
}

enum Lookup: Sendable {
    case present(ProcessRecord)
    case gone
    case unavailable(String)
}

enum ActionOutcome: Equatable {
    case waiting, cancelled, exited, alreadyGone, replaced, timedOut, denied(String), blocked(String)
    var message: String {
        switch self {
        case .waiting: "Waiting for the selected process to exit…"
        case .cancelled: "Cancelled. No request was sent."
        case .exited: "Exited. The next system sample is shown separately."
        case .alreadyGone: "The selected process had already exited."
        case .replaced: "This PID now belongs to a different process. No retry was sent."
        case .timedOut: "The selected process is still running. The request timed out."
        case .denied(let reason), .blocked(let reason): reason
        }
    }
}

@MainActor
protocol ProcessControlling {
    func lookUp(_ pid: Int32) -> Lookup
    /// Must revalidate identity and owner synchronously immediately before acting.
    func send(_ operation: ProcessOperation, to target: Target, policy: ActionPolicy,
              protections: [Protection]) -> ActionOutcome?
}

@MainActor
final class ActionEngine {
    static let freshness: Duration = .seconds(7)
    private let controller: any ProcessControlling
    private let clock: any SampleClock
    private let timeout: Duration
    private var forceTicket: (target: Target, deadline: Tick)?
    private(set) var busy = false

    init(controller: any ProcessControlling, clock: any SampleClock, timeout: Duration = .seconds(5)) {
        self.controller = controller
        self.clock = clock
        self.timeout = timeout
    }

    func canForce(_ target: Target) -> Bool {
        guard let forceTicket else { return false }
        return !busy && clock.now < forceTicket.deadline && target.sameIdentity(as: forceTicket.target)
    }

    func perform(_ operation: ProcessOperation, target: Target, policy: ActionPolicy,
                 protections: [Protection]) async -> ActionOutcome {
        guard !busy else { return .blocked("Another request is still in progress.") }
        guard target.sampledAt.duration(to: clock.now) <= Self.freshness else {
            return .blocked("Process data is stale. Refresh and review the target again.")
        }
        guard (operation == .quit && target.app != nil) || (operation == .stop && target.app == nil)
                || (operation == .force && canForce(target)) else {
            return .blocked("Review the action for this target first.")
        }
        if let reason = policy.issue(for: target.row, app: target.app, ancestry: [],
                                     ambiguous: target.ambiguous, protections: protections) {
            return .blocked(reason)
        }
        forceTicket = nil
        busy = true
        defer { busy = false }
        if let error = controller.send(operation, to: target, policy: policy, protections: protections) { return error }

        let deadline = clock.now.advanced(by: timeout)
        while true {
            switch controller.lookUp(target.row.pid) {
            case .gone: return .exited
            case .present(let row) where row.id != target.row.id: return .replaced
            case .unavailable(let message):
                return .denied("Couldn’t verify exit. \(message)")
            case .present:
                if clock.now >= deadline {
                    if operation != .force { forceTicket = (target, clock.now.advanced(by: .seconds(120))) }
                    return .timedOut
                }
                do { try await clock.sleep(for: .milliseconds(150)) }
                catch { return .blocked("Exit verification was interrupted.") }
            }
        }
    }
}
