import AppKit
import Observation
import ServiceManagement
import UserNotifications

enum InspectorPage: String, CaseIterable, Identifiable {
    case overview = "Overview", apps = "Apps", processes = "Processes"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .apps: "square.grid.2x2"
        case .processes: "list.bullet.indent"
        }
    }
}

enum ProcessScope: Hashable {
    case all, unassigned, app(ProcessID)
}

struct Confirmation: Identifiable {
    let id = UUID()
    let operation: ProcessOperation
    let target: Target
    let context: String
    let revision: Int

    var title: String { "\(operation.rawValue): \(target.name)?" }

    var message: String {
        let pid = target.row.pid
        switch operation {
        case .quit:
            return "PID \(pid). The app can ask you to save work before it quits. Work running inside the app may be interrupted."
        case .stop:
            return "PID \(pid). \(context)Only this process will receive a stop request. Work may be interrupted, and a watcher may restart it."
        case .force:
            let scope = target.app == nil ? "Only PID \(pid) will receive a force stop request."
                : "This will force quit the app at PID \(pid)."
            return "\(scope) Unsaved work may be lost."
        }
    }
}

struct ActionStatus {
    let target: Target
    let outcome: ActionOutcome
    var replacement: Bool = false
}

@MainActor
@Observable
final class Store {
    private let memorySampler: any MemorySampling
    private let processSampler: any ProcessSampling
    private let appInventory: any ApplicationInventory
    private let clock: any SampleClock
    private let preferences: any Preferences
    private let actions: ActionEngine
    private let events = WorkspaceEvents()
    private let services = SystemServices()
    let policy: ActionPolicy

    private(set) var memory: Reading<HostMemory>?
    private(set) var swap: Reading<Bytes>?
    private(set) var memoryFailed = false
    private(set) var swapFailed = false
    private(set) var inventory: Reading<Inventory>?
    private(set) var inventoryFailed = false
    private(set) var pressure: Pressure = .unknown
    private(set) var protections: [Protection]
    private(set) var focus: [String: Date]
    private(set) var frontmost: Int32?
    private(set) var outcome: ActionStatus?
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var loginError: String?
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var notificationsEnabled: Bool
    private(set) var notificationError: String?
    private(set) var notificationBusy = false

    var page: InspectorPage = .apps
    var appSelection: ProcessID?
    var processSelection: ProcessID?
    var scope: ProcessScope = .all
    var query = ""
    var confirmation: Confirmation?

    @ObservationIgnored private var observing = false
    @ObservationIgnored private var memoryTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?
    @ObservationIgnored private var memoryResample = false
    @ObservationIgnored private var inventoryResample = false
    @ObservationIgnored private var visible: Set<String> = []
    @ObservationIgnored private var memoryAttempt: Tick?
    @ObservationIgnored private var inventoryAttempt: Tick?
    @ObservationIgnored private var revision = 0
    private var sleeping = false
    private var invalidMemory = false
    private var invalidInventory = false
    private var inventoryExpired = false
    @ObservationIgnored private var lastNotified: Tick?
    @ObservationIgnored private var respawn: (record: ProcessRecord, parent: ProcessID, before: Set<ProcessID>, date: Date, at: Tick)?

    init(memory: any MemorySampling, processes: any ProcessSampling, apps: any ApplicationInventory,
         clock: any SampleClock, preferences: any Preferences, controller: any ProcessControlling,
         policy: ActionPolicy) {
        memorySampler = memory
        processSampler = processes
        appInventory = apps
        self.clock = clock
        self.preferences = preferences
        actions = ActionEngine(controller: controller, clock: clock)
        self.policy = policy
        protections = preferences.protections
        focus = preferences.focus
        notificationsEnabled = preferences.notifications
    }

    static func live() -> Store {
        let sampler = DarwinSampler()
        return Store(memory: sampler, processes: sampler, apps: Workspace(), clock: SystemClock(),
                     preferences: LocalPreferences(), controller: DarwinControl(),
                     policy: ActionPolicy(user: getuid(), ownPID: getpid()))
    }

    func start(observeSystem: Bool = true) {
        guard !observing else { return }
        observing = true
        if observeSystem {
            if let app = NSWorkspace.shared.frontmostApplication { observe(Workspace.describe(app)) }
            events.start { [weak self] in self?.observe($0) } sleep: { [weak self] in self?.setSleeping($0) }
            services.observePressure { [weak self] in self?.setPressure($0) }
        }
        refreshMemory()
        Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard let self else { break }
                self.pulse()
            }
        }
    }

    func setVisible(_ key: String, _ on: Bool) {
        if on {
            let wasClosed = visible.isEmpty
            visible.insert(key)
            if wasClosed {
                refreshMemory()
                refreshInventory()
            }
        } else {
            visible.remove(key)
        }
    }

    func refresh() {
        refreshMemory()
        refreshInventory()
    }

    private func pulse() {
        guard !sleeping else { return }
        if !visible.isEmpty {
            let expired = inventory?.fresh(at: clock.now, within: ActionEngine.freshness) == false
            if expired != inventoryExpired { inventoryExpired = expired }
        }
        let memoryInterval: Duration = memoryFailed || swapFailed ? .seconds(8) : .seconds(2)
        if due(memoryAttempt, every: visible.isEmpty ? .seconds(20) : memoryInterval) { refreshMemory() }
        if !visible.isEmpty && due(inventoryAttempt, every: inventoryFailed ? .seconds(8) : .seconds(2)) {
            refreshInventory()
        }
    }

    private func due(_ last: Tick?, every interval: Duration) -> Bool {
        last.map { $0.duration(to: clock.now) >= interval } ?? true
    }

    private func refreshMemory() {
        guard !sleeping, memoryTask == nil else { return }
        let revision = revision
        let at = clock.now
        memoryAttempt = at
        memoryTask = Task { [weak self, memorySampler, clock] in
            let value = await memorySampler.sampleMemory()
            guard let self else { return }
            memoryTask = nil
            defer {
                if memoryResample { memoryResample = false; refreshMemory() }
            }
            guard self.revision == revision, !sleeping else {
                if !sleeping { refreshMemory() }
                return
            }
            memoryFailed = value.occupied == nil || value.compressed == nil
            swapFailed = value.swap == nil
            if !memoryFailed || memory == nil { memory = Reading(value: value, at: at, date: clock.date) }
            if let used = value.swap { swap = Reading(value: used, at: at, date: clock.date) }
            invalidMemory = false
        }
    }

    private func refreshInventory() {
        guard !sleeping, inventoryTask == nil else { return }
        let revision = revision
        let at = clock.now
        let date = clock.date
        let apps = appInventory.applications()
        frontmost = appInventory.frontmostPID
        let prior = invalidInventory ? nil : inventory
        inventoryAttempt = at
        inventoryTask = Task { [weak self, processSampler] in
            let records = await processSampler.sampleProcesses()
            let next: Inventory?
            if let records {
                next = await Task.detached(priority: .utility) {
                    Inventory(processes: records, running: apps, prior: prior, at: at)
                }.value
            } else {
                next = nil
            }
            guard let self else { return }
            inventoryTask = nil
            defer {
                if inventoryResample { inventoryResample = false; refreshInventory() }
            }
            guard self.revision == revision, !sleeping else {
                if !sleeping && !visible.isEmpty { refreshInventory() }
                return
            }
            guard let next else { inventoryFailed = true; return }
            inventory = Reading(value: next, at: at, date: date)
            inventoryFailed = false
            invalidInventory = false
            inventoryExpired = false
            checkReplacement(next)
        }
    }

    private func setSleeping(_ value: Bool) {
        revision += 1
        sleeping = value
        invalidMemory = true
        invalidInventory = true
        confirmation = nil
        pressure = .unknown
        if !value {
            refreshMemory()
            if !visible.isEmpty { refreshInventory() }
        }
    }

    var currentTime: Tick { clock.now }
    var inventoryIsFresh: Bool {
        !sleeping && !invalidInventory && !inventoryFailed && !inventoryExpired
            && inventory?.fresh(at: clock.now, within: ActionEngine.freshness) == true
    }

    var memoryIsStale: Bool {
        sleeping || invalidMemory || memoryFailed || memory?.fresh(at: clock.now, within: .seconds(35)) == false
    }

    var swapIsStale: Bool {
        sleeping || invalidMemory || swapFailed || swap?.fresh(at: clock.now, within: .seconds(35)) == false
    }

    func observe(_ app: RunningApp) {
        frontmost = app.pid
        guard let key = app.bundleID, app.regular else { return }
        focus[key] = clock.date
        if focus.count > 200 {
            let recent = focus.sorted { $0.value > $1.value }.prefix(200)
            focus = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        preferences.focus = focus
    }

    func clearFocus() {
        focus = [:]
        preferences.focus = [:]
    }

    func setPressure(_ value: Pressure) {
        guard !sleeping else { return }
        let changed = value != pressure
        pressure = value
        guard changed, value == .elevated || value == .critical, notificationsEnabled,
              due(lastNotified, every: .seconds(600)) else { return }
        lastNotified = clock.now
        Task { await services.notify(value) }
    }

    var candidates: [ReviewCandidate] {
        guard inventoryIsFresh, let inventory else { return [] }
        return Recommendations.candidates(in: inventory.value, frontmost: frontmost,
                                          policy: policy, protections: protections, focus: focus)
    }

    func navigate(_ page: InspectorPage, selection: ProcessID? = nil, scope: ProcessScope = .all) {
        query = ""
        self.page = page
        self.scope = scope
        if page == .apps { appSelection = selection }
        if page == .processes { processSelection = selection }
    }

    func target(for row: ProcessRecord, app: RunningApp? = nil) -> Target? {
        guard let inventory else { return nil }
        return Target(row: row, app: app, name: app?.name ?? row.name, sampledAt: inventory.at,
                      ambiguous: inventory.value.ambiguous.contains(row.id))
    }

    func menuTarget(for id: ProcessID) -> Target? {
        guard let inventory = inventory?.value, let row = inventory.records[id] else { return nil }
        return target(for: row, app: inventory.regularAppsByPID[row.pid]?.app)
    }

    private func ancestry(_ id: ProcessID) -> [ProcessRecord] {
        guard let inventory = inventory?.value else { return [] }
        var next = inventory.parents[id]
        var rows: [ProcessRecord] = []
        while let parent = next, let record = inventory.records[parent] {
            rows.append(record)
            next = inventory.parents[parent]
        }
        return rows
    }

    func issue(_ target: Target) -> String? {
        guard inventoryIsFresh else { return "Process data is stale or unavailable. Refresh to act." }
        if target.app == nil, inventory?.value.regularAppsByPID[target.row.pid] != nil {
            return "Use Quit App in Apps for this process."
        }
        return policy.issue(for: target.row, app: target.app, ancestry: ancestry(target.row.id),
                            ambiguous: target.ambiguous, protections: protections)
    }

    func protection(for target: Target) -> Protection? {
        if let app = target.app { return app.protection }
        if let path = target.row.path, target.row.uid == policy.user {
            return Protection(key: .executable(path), label: target.name, bundlePath: nil)
        }
        return nil
    }

    func toggleProtection(_ rule: Protection) {
        if protections.contains(where: { $0.key == rule.key }) { protections.removeAll { $0.key == rule.key } }
        else { protections.append(rule) }
        preferences.protections = protections
    }

    var actionWaiting: Bool { outcome?.outcome == .waiting }

    func canForce(_ target: Target) -> Bool {
        outcome?.target.sameIdentity(as: target) == true && outcome?.outcome == .timedOut && actions.canForce(target)
    }

    func propose(_ operation: ProcessOperation, target: Target) {
        confirmation = review(operation, target: target)
    }

    func review(_ operation: ProcessOperation, target: Target) -> Confirmation? {
        guard !actionWaiting, issue(target) == nil, operation != .force || canForce(target) else { return nil }
        let parent = inventory?.value.parents[target.row.id].flatMap { inventory?.value.records[$0]?.name }
        let context = parent.map { "Observed parent: \($0). " } ?? ""
        return Confirmation(operation: operation, target: target, context: context, revision: revision)
    }

    func cancel(_ proposal: Confirmation) {
        if proposal.operation != .force && !actionWaiting {
            outcome = ActionStatus(target: proposal.target, outcome: .cancelled)
        }
        if confirmation?.id == proposal.id { confirmation = nil }
    }

    func confirm(_ proposal: Confirmation) async {
        let original = proposal.target
        if confirmation?.id == proposal.id { confirmation = nil }
        guard !actionWaiting else { return }
        guard proposal.revision == revision, inventoryIsFresh, let inventory else {
            outcome = ActionStatus(target: original, outcome: .blocked("Process data is stale. Refresh and review the target."))
            return
        }
        guard let live = inventory.value.records[original.row.id] else {
            let replacement = inventory.value.records.keys.contains { $0.pid == original.row.pid }
            outcome = ActionStatus(target: original, outcome: replacement ? .replaced : .alreadyGone)
            return
        }
        let app = original.app.flatMap { _ in inventory.value.apps.first { $0.id == live.id }?.app }
        guard live.path == original.row.path, live.uid == original.row.uid,
              app?.bundleID == original.app?.bundleID, app?.bundlePath == original.app?.bundlePath,
              (original.app == nil) == (app == nil), let target = target(for: live, app: app) else {
            outcome = ActionStatus(target: original, outcome: .blocked("The target changed. Review the current process."))
            return
        }
        if let issue = issue(target) {
            outcome = ActionStatus(target: target, outcome: .blocked(issue))
            return
        }
        outcome = ActionStatus(target: target, outcome: .waiting)
        respawn = nil
        let parent = inventory.value.parents[live.id]
        let started = clock.date
        let result = await actions.perform(proposal.operation, target: target, policy: policy, protections: protections)
        outcome = ActionStatus(target: target, outcome: result)
        if result == .exited, target.app == nil, let parent, live.path != nil {
            respawn = (live, parent, Set(inventory.value.records.keys), started, clock.now)
        }
        memoryResample = memoryTask != nil
        inventoryResample = inventoryTask != nil
        refresh()
    }

    private func checkReplacement(_ next: Inventory) {
        guard let watch = respawn else { return }
        if watch.at.duration(to: clock.now) > .seconds(12) || next.records[watch.parent] == nil {
            respawn = nil
            return
        }
        if next.records.values.contains(where: { row in
            !watch.before.contains(row.id) && row.path == watch.record.path && row.uid == watch.record.uid
                && next.parents[row.id] == watch.parent && (row.id.start?.date ?? .distantPast) >= watch.date
        }) {
            outcome?.replacement = true
            respawn = nil
        }
    }

    func refreshSettings() async {
        loginStatus = services.loginStatus
        notificationStatus = await services.notificationStatus()
    }

    func setLogin(_ value: Bool) {
        loginError = nil
        do { try services.setLogin(value) }
        catch { loginError = error.localizedDescription }
        loginStatus = services.loginStatus
    }

    func setNotifications(_ value: Bool) async {
        notificationError = nil
        guard !notificationBusy else { return }
        notificationBusy = true
        defer { notificationBusy = false }
        if value {
            do { notificationsEnabled = try await services.authorizeNotifications() }
            catch { notificationError = error.localizedDescription; notificationsEnabled = false }
        } else { notificationsEnabled = false }
        preferences.notifications = notificationsEnabled
        notificationStatus = await services.notificationStatus()
    }
}
