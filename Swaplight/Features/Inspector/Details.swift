import SwiftUI

struct Details: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            if let inventory = store.inventory?.value, store.page == .apps,
               let group = inventory.apps.first(where: { $0.id == store.appSelection && inventory.isReviewable($0, policy: store.policy) }) {
                panel {
                    heading(group.name, label: "Selected App", icon: "square.grid.2x2")
                    let focused = group.app.bundleID.flatMap { store.focus[$0] }
                    Text(focused.map { "Last observed focus: \($0.formatted(.relative(presentation: .named)))" } ?? "Focus: Not observed")
                        .foregroundStyle(.secondary)
                        .help(focused?.formatted(date: .abbreviated, time: .standard) ?? "Not observed")
                    Divider()
                    field("Footprint", group.footprint.formatted)
                    field("Processes", group.main.id.start == nil ? "Unavailable" : "\(group.count) observed")
                    if group.footprint.unavailable > 0 { field("Without footprint", "\(group.footprint.unavailable)") }
                    field("PID", String(group.main.pid))
                    field("Owner", owner(group.main))
                    field("Executable", group.main.path ?? "Unavailable", path: true)
                    Divider()
                    let contributors = group.members.filter { inventory.isReviewable($0, policy: store.policy) }
                    if !contributors.isEmpty {
                        Button("View \(contributors.count) Processes") {
                            let main = contributors.first { $0.id == group.id }
                            store.navigate(.processes, selection: main?.id, scope: .app(group.id))
                        }
                    }
                    if let target = store.target(for: group.main, app: group.app) {
                        actions(target, operation: .quit)
                    }
                    if !contributors.isEmpty {
                        Divider()
                        Text("Observed contributors").font(.headline)
                        ForEach(contributors.sorted { ($0.footprint?.value ?? 0) > ($1.footprint?.value ?? 0) }) { row in
                            Button {
                                store.navigate(.processes, selection: row.id, scope: .app(group.id))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(row.name).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(row.footprint?.formatted ?? "Unavailable").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(inventory.context(for: row)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Text("App footprints are estimates. Some helpers may be missing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let inventory = store.inventory?.value, store.page == .processes,
                      let id = store.processSelection, let row = inventory.records[id] {
                panel {
                    heading(row.name, label: "Selected Process", icon: "terminal")
                    Text(inventory.context(for: row)).foregroundStyle(.secondary)
                    Divider()
                    field("PID", String(row.pid))
                    field("Owner", owner(row))
                    field("Parent", parent(row, in: inventory))
                    field("Executable", row.path ?? "Unavailable", path: true)
                    field("Footprint", row.footprint?.formatted ?? "Unavailable")
                    field("Resident", row.resident?.formatted ?? "Unavailable")
                    field("Recent CPU", inventory.activity[id]?.cpuPercent.map {
                        $0.formatted(.number.precision(.fractionLength(1))) + "%"
                    } ?? "Insufficient evidence")
                    field("Recent disk I/O", inventory.activity[id].flatMap { activity in
                        activity.diskBytes.map { "\($0.formatted) / \(activity.seconds.formatted(.number.precision(.fractionLength(1))))s" }
                    } ?? "Insufficient evidence")
                    field("Uptime", row.id.start.map {
                        let baseline = store.inventory?.date.timeIntervalSince($0.date) ?? 0
                        let elapsed = store.inventory?.at.duration(to: store.currentTime).components.seconds ?? 0
                        let seconds = max(0, Int(baseline) + Int(elapsed))
                        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                    } ?? "Unavailable")
                    Divider()
                    if let target = store.menuTarget(for: row.id) {
                        actions(target, operation: target.app == nil ? .stop : .quit)
                    }
                }
            } else {
                let wasSelected = (store.page == .apps && store.appSelection != nil)
                    || (store.page == .processes && store.processSelection != nil)
                InspectorEmpty(title: wasSelected ? "Item no longer observed" : "No item selected", icon: "sidebar.trailing",
                               description: wasSelected ? "Select a current row to review it."
                                   : "Select an app or process to see its details.")
            }
        }
    }

    private func panel(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, content: content)
                .padding(14)
        }
        .accessibilityIdentifier("item-details")
    }

    private func heading(_ name: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.title3.weight(.semibold)).textSelection(.enabled)
        }
    }

    private func field(_ label: String, _ value: String, path: Bool = false) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(path ? 4 : 2)
                .help(value)
        } label: {
            Text(label).foregroundStyle(.secondary)
        }.font(.callout)
    }

    private func owner(_ row: ProcessRecord) -> String {
        row.uid.map { $0 == store.policy.user ? "Current user (\($0))" : "UID \($0)" } ?? "Unavailable"
    }

    private func parent(_ row: ProcessRecord, in inventory: Inventory) -> String {
        if let id = inventory.parents[row.id], let parent = inventory.records[id] {
            return "\(parent.name) (\(parent.pid))"
        }
        return row.parentPID.map { "PID \($0) · not verified" } ?? "Unavailable"
    }

    @ViewBuilder private func actions(_ target: Target, operation: ProcessOperation) -> some View {
        if let rule = store.protection(for: target) {
            let protected = store.protections.contains { $0.key == rule.key }
            Toggle("Keep Running", isOn: Binding(get: { protected }, set: { _ in store.toggleProtection(rule) }))
                .help("Protect this \(target.app == nil ? "executable" : "app") from suggestions and process actions.")
        }
        if let issue = store.issue(target) {
            Label("Read Only", systemImage: "lock").font(.callout.weight(.medium))
            Text(issue).font(.caption).foregroundStyle(.secondary)
        } else if store.canForce(target) {
            Button("Review Force Stop…") { store.propose(.force, target: target) }
            Text("The original request timed out. Force stopping may discard unsaved work.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button(operation.rawValue, role: .destructive) { store.propose(operation, target: target) }
                .disabled(store.actionWaiting)
            Text(operation == .quit ? "Lets the app handle unsaved work." : "Requests termination of this process only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
