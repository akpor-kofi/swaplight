import Foundation

enum Evidence: String, Sendable {
    case main = "Verified app process"
    case bundle = "Executable inside the app bundle"
    case descendant = "Observed app ancestry"
    case both = "App bundle and observed ancestry"
}

struct AppGroup: Identifiable, Sendable {
    let app: RunningApp
    let main: ProcessRecord
    let members: [ProcessRecord]
    let footprint: Footprint
    var id: ProcessID { main.id }
    var name: String { app.name }
    var count: Int { members.count }
}

struct Inventory: Sendable {
    let records: [ProcessID: ProcessRecord]
    let parents: [ProcessID: ProcessID]
    let children: [ProcessID: [ProcessID]]
    let apps: [AppGroup]
    let regularAppsByPID: [Int32: AppGroup]
    let attribution: [ProcessID: ProcessID]
    let evidence: [ProcessID: Evidence]
    let ambiguous: Set<ProcessID>
    let terminalJobs: [ProcessID: ProcessID]
    let activity: [ProcessID: Activity]

    init(processes: [ProcessRecord], running: [RunningApp], prior: Reading<Inventory>?, at: Tick) {
        let pids = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = pids.values.sorted {
            switch ($0.id.start, $1.id.start) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.pid < $1.pid
            }
        }
        records = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var parents = [ProcessID: ProcessID]()
        var children = [ProcessID: [ProcessID]]()
        for row in ordered {
            // Strict order both rejects impossible parent links and makes cycles impossible.
            guard let ppid = row.parentPID, let parent = pids[ppid], let a = parent.id.start,
                  let b = row.id.start, a < b else { continue }
            parents[row.id] = parent.id
            children[parent.id, default: []].append(row.id)
        }
        self.parents = parents
        self.children = children

        let listed = running.filter { $0.regular || $0.bundlePath?.hasSuffix(".app") == true }
        let seeds = listed.compactMap { app -> (ProcessID, RunningApp)? in
            guard let main = pids[app.pid], app.matches(main) else { return nil }
            return (main.id, app)
        }
        let byID = Dictionary(seeds, uniquingKeysWith: { first, _ in first })
        let bundleSeeds = byID.compactMap { id, app in app.bundlePath.map { (id, $0 + "/") } }
        var attribution = [ProcessID: ProcessID]()
        var evidence = [ProcessID: Evidence]()
        var ambiguous = Set<ProcessID>()
        var jobs = [ProcessID: ProcessID]()
        var members = [ProcessID: [ProcessRecord]]()
        var activity = [ProcessID: Activity]()
        for row in ordered {
            let id = row.id
            if let prior, let measured = Activity(now: row, previous: prior.value.records[id],
                                                  elapsed: prior.at.duration(to: at)) {
                activity[id] = measured
            }
            let parentID = parents[id]
            let parent = parentID.flatMap { pids[$0.pid] }
            if let parent, parent.uid == row.uid, row.uid != nil, parent.terminal == row.terminal, parent.isShell,
               !row.isShell, byID[id] == nil {
                jobs[id] = id
            } else if let parentID, byID[id] == nil, row.uid != nil, parent?.uid == row.uid {
                jobs[id] = jobs[parentID]
            }
            if byID[id] != nil {
                attribution[id] = id
                evidence[id] = .main
                members[id, default: []].append(row)
                continue
            }
            guard row.uid != nil, id.start != nil, let path = row.path else { continue }
            let ancestry = parentID.flatMap { attribution[$0] }.flatMap { owner in
                pids[owner.pid]?.uid == row.uid && parent?.uid == row.uid && !row.isShell && jobs[id] == nil ? owner : nil
            }
            let matches = bundleSeeds.filter { owner, prefix in
                pids[owner.pid]?.uid == row.uid && path.hasPrefix(prefix)
            }
            let longest = matches.map { $0.1.count }.max()
            let bundle = matches.filter { $0.1.count == longest }.map(\.0)
            let owner: ProcessID
            if let ancestry {
                guard bundle.isEmpty || bundle.contains(ancestry) else {
                    ambiguous.insert(id)
                    continue
                }
                owner = ancestry
                evidence[id] = bundle.isEmpty ? .descendant : .both
            } else if bundle.count == 1, let match = bundle.first {
                owner = match
                evidence[id] = .bundle
            } else {
                if bundle.count > 1 || parentID.map(ambiguous.contains) == true { ambiguous.insert(id) }
                continue
            }
            attribution[id] = owner
            members[owner, default: []].append(row)
        }
        self.attribution = attribution
        self.evidence = evidence
        self.ambiguous = ambiguous
        terminalJobs = jobs
        self.activity = activity
        let grouped: [AppGroup] = byID.compactMap { id, app in
            guard let rows = members[id], let main = pids[id.pid] else { return nil }
            return AppGroup(app: app, main: main, members: rows, footprint: Footprint(rows))
        }
        let verifiedPIDs = Set(byID.keys.map(\.pid))
        let unverified = listed.filter { !verifiedPIDs.contains($0.pid) && $0.pid > 0 }.map { app in
            let placeholder = ProcessRecord(id: ProcessID(pid: app.pid, start: nil), name: app.name,
                                            path: app.executable, uid: nil, parentPID: nil, terminal: nil,
                                            footprint: nil, resident: nil, cpuTime: nil, diskRead: nil, diskWritten: nil)
            return AppGroup(app: app, main: placeholder, members: [], footprint: Footprint([]))
        }
        let appGroups = (grouped + unverified).sorted { $0.id.pid < $1.id.pid }
        apps = appGroups
        regularAppsByPID = Dictionary(appGroups.filter { $0.app.regular }.map { ($0.main.pid, $0) },
                                      uniquingKeysWith: { first, _ in first })
    }

    // Keep Running is a user choice. Preserve those rows so the rule remains discoverable.
    func isReviewable(_ row: ProcessRecord, policy: ActionPolicy) -> Bool {
        row.footprint != nil && policy.issue(for: row, app: regularAppsByPID[row.pid]?.app, ancestry: [],
                                             ambiguous: ambiguous.contains(row.id), protections: []) == nil
    }

    func isReviewable(_ group: AppGroup, policy: ActionPolicy) -> Bool {
        group.footprint.known != nil && policy.issue(for: group.main, app: group.app, ancestry: [],
                                                      ambiguous: ambiguous.contains(group.id), protections: []) == nil
    }

    func matches(_ row: ProcessRecord, query: String) -> Bool {
        if query.isEmpty { return true }
        if let pid = Int32(query), pid > 0 { return row.pid == pid }
        return [row.name, row.path, regularAppsByPID[row.pid]?.name].compactMap { $0 }
            .contains { $0.localizedStandardContains(query) }
    }

    func context(for row: ProcessRecord) -> String {
        if let root = terminalJobs[row.id], let job = records[root] {
            if root == row.id, let shell = parents[root].flatMap({ records[$0] }) {
                return "Command below \(shell.name)"
            }
            if root != row.id { return "Observed in \(job.name) job" }
        }
        if let evidence = evidence[row.id] { return evidence.rawValue }
        if ambiguous.contains(row.id) { return "Conflicting app evidence" }
        return "Unassigned"
    }
}

struct ReviewCandidate: Identifiable {
    let id: ProcessID
    let name: String
    let reason: String
    let footprint: Footprint
    let app: Bool
}

enum Recommendations {
    static let focusBonusWindow: Duration = .seconds(2 * 60 * 60)
    private static let maxFocusBonus = 0.25

    static func candidates(in inventory: Inventory, frontmost: Int32?, policy: ActionPolicy,
                           protections: [Protection], focus: [String: FocusObservation], now: Tick) -> [ReviewCandidate] {
        guard let frontmost else { return [] }
        let threshold: UInt64 = 256 * 1_024 * 1_024
        typealias Ranked = (candidate: ReviewCandidate, footprint: Bytes, score: Double)
        let apps = inventory.apps.compactMap { group -> Ranked? in
            guard group.app.regular, group.main.pid != frontmost,
                  let footprint = group.footprint.known, footprint.value >= threshold,
                  policy.issue(for: group.main, app: group.app, ancestry: [], ambiguous: false,
                               protections: protections) == nil else { return nil }
            let focused = group.app.bundleID.flatMap { focus[$0] }
            let reason = focused.map { "Large footprint · focused \($0.date.formatted(.relative(presentation: .named)))" }
                ?? "Large footprint · focus not observed"
            let fraction = focused.map { min(1, max(0, $0.at.duration(to: now) / focusBonusWindow)) } ?? 0
            let candidate = ReviewCandidate(id: group.id, name: group.name, reason: reason,
                                            footprint: group.footprint, app: true)
            return (candidate, footprint, Double(footprint.value) * (1 + maxFocusBonus * fraction))
        }
        var jobMembers: [ProcessID: [ProcessRecord]] = [:]
        for (id, root) in inventory.terminalJobs where inventory.attribution[id] == nil && !inventory.ambiguous.contains(id) {
            if let member = inventory.records[id] { jobMembers[root, default: []].append(member) }
        }
        let jobs = jobMembers.compactMap { id, members -> Ranked? in
            guard inventory.attribution[id] == nil, let row = inventory.records[id] else { return nil }
            let footprint = Footprint(members)
            guard let known = footprint.known, known.value >= threshold else { return nil }
            var lineage: [ProcessRecord] = []
            var parent = inventory.parents[id]
            while let key = parent, let record = inventory.records[key] {
                lineage.append(record)
                parent = inventory.parents[key]
            }
            guard !lineage.contains(where: { $0.pid == frontmost }),
                  policy.issue(for: row, app: nil, ancestry: lineage, ambiguous: inventory.ambiguous.contains(id),
                               protections: protections) == nil else { return nil }
            let cpu = inventory.activity[id]?.cpuPercent.map {
                $0.formatted(.number.precision(.fractionLength(0))) + "% CPU at job root"
            }
            let reason = "Large job to inspect · " + (cpu ?? "\(members.count) observed")
            let candidate = ReviewCandidate(id: id, name: row.name, reason: reason, footprint: footprint, app: false)
            return (candidate, known, Double(known.value))
        }
        return (apps + jobs).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.footprint != rhs.footprint { return lhs.footprint > rhs.footprint }
            return lhs.candidate.id.pid < rhs.candidate.id.pid
        }.map(\.candidate)
    }
}
