import AppKit
import Darwin

@MainActor
struct DarwinControl: ProcessControlling {
    func lookUp(_ pid: Int32) -> Lookup {
        guard pid > 1 else { return .unavailable("Invalid or reserved PID.") }
        let (bsd, error) = Kernel.bsd(pid)
        guard let bsd else { return error == ESRCH ? .gone : .unavailable(Self.errorText(error)) }
        // A zombie has exited even if its parent has not collected its wait status.
        if bsd.pbi_status == SZOMB { return .gone }
        guard DarwinSampler.start(bsd) != nil else { return .unavailable("Start identity is unavailable.") }
        return .present(DarwinSampler.record(pid, bsd: bsd, path: Kernel.path(pid)))
    }

    func send(_ operation: ProcessOperation, to target: Target, policy: ActionPolicy,
              protections: [Protection]) -> ActionOutcome? {
        let pid = target.row.pid
        guard pid > 1, pid != policy.ownPID else { return .blocked("Invalid or protected PID.") }
        let live: ProcessRecord
        switch lookUp(pid) {
        case .gone: return .alreadyGone
        case .unavailable(let text): return .denied(text)
        case .present(let row): live = row
        }
        guard live.id == target.row.id else { return .replaced }
        guard let path = live.path, path == target.row.path, let uid = live.uid, uid == target.row.uid else {
            return .blocked("The owner or executable changed. Refresh and review the target.")
        }

        let running = NSWorkspace.shared.runningApplications
        let currentApp = running.first { $0.processIdentifier == pid }
        let currentDescription = currentApp.map(Workspace.describe)
        if let expected = target.app {
            guard let app = currentDescription, app.matches(live),
                  app.bundleID == expected.bundleID, app.bundlePath == expected.bundlePath else {
                return .blocked("The running app could no longer be verified.")
            }
        } else if currentDescription?.regular == true {
            return .blocked("Use Quit App for this running application.")
        }

        // Rebuild just the relevant ancestry. Never trust cached parent links for protection.
        var lineage: [ProcessRecord] = []
        var child = live
        var complete = true
        while let parent = child.parentPID, parent > 1 {
            guard lineage.count < 128, case .present(let row) = lookUp(parent),
                  let a = row.id.start, let b = child.id.start, a < b else { complete = false; break }
            if row.uid != uid { break }
            if row.path == nil { complete = false }
            lineage.append(row)
            child = row
        }
        var rules = protections
        let applications = running.map(Workspace.describe)
        for app in applications {
            if let rule = app.protection, protections.contains(where: { $0.key == rule.key }) { rules.append(rule) }
        }
        if !complete && rules.contains(where: { if case .app = $0.key { true } else { false } }) {
            return .blocked("Couldn’t rule out a Keep Running match in the current parent chain.")
        }
        // Multiple independently plausible app owners are a reason to stop and review.
        let byBundle = applications.filter { app in
            app.bundlePath.map { path.hasPrefix($0 + "/") } == true
        }
        let longest = byBundle.compactMap { $0.bundlePath?.count }.max()
        let closestBundles = byBundle.filter { $0.bundlePath?.count == longest }
        let nearestApp = lineage.lazy.compactMap { ancestor in applications.first { $0.matches(ancestor) } }.first
        let conflict = target.app == nil && (closestBundles.count > 1 && nearestApp == nil
            || (!closestBundles.isEmpty && nearestApp != nil && !closestBundles.contains { $0.pid == nearestApp?.pid }))
        if let issue = policy.issue(for: live, app: target.app == nil ? nil : currentDescription, ancestry: lineage,
                                    ambiguous: target.ambiguous || conflict, protections: rules) {
            return .blocked(issue)
        }

        // No await, UI work, or task hop between this check and the OS request.
        guard let finalPath = Kernel.path(pid), finalPath == path else {
            return .blocked("The executable changed or is unavailable.")
        }
        let (final, error) = Kernel.bsd(pid)
        guard let final else { return error == ESRCH ? .alreadyGone : .denied(Self.errorText(error)) }
        guard DarwinSampler.start(final) == live.id.start else { return .replaced }
        guard final.pbi_status != SZOMB else { return .alreadyGone }
        guard final.pbi_uid == uid, final.pbi_ruid == uid, final.pbi_svuid == uid,
              final.pbi_ppid == live.parentPID.map(UInt32.init) else {
            return .blocked("The owner or parent changed. Refresh and review the target.")
        }
        if target.app != nil, let currentApp {
            let accepted = operation == .force ? currentApp.forceTerminate() : currentApp.terminate()
            return accepted ? nil : .denied("macOS did not accept the \(operation.rawValue.lowercased()) request.")
        }
        let signal = operation == .force ? SIGKILL : SIGTERM
        guard Darwin.kill(pid, signal) == 0 else {
            let error = errno
            return error == ESRCH ? .alreadyGone : .denied(Self.errorText(error))
        }
        return nil
    }

    private static func errorText(_ error: Int32) -> String {
        guard error != 0 else { return "macOS did not provide process details." }
        return "macOS: \(POSIXErrorCode(rawValue: error).map { POSIXError($0).localizedDescription } ?? String(cString: strerror(error)))"
    }
}
