import SwiftUI

private struct ProcessRow: Identifiable {
    let process: ProcessRecord
    let context: String
    let depth: Int
    let expandable: Bool
    var id: ProcessID { process.id }
    var name: String { process.name }
    var pid: Int32 { process.pid }
    var bytes: UInt64? { process.footprint?.value }
}

struct ProcessesTable: View {
    @Environment(Store.self) private var store
    @State private var flat = false
    @State private var expanded: Set<ProcessID> = []
    @State private var collapsed: Set<ProcessID> = []
    @State private var sort = [KeyPathComparator(\ProcessRow.bytes, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        let result = rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Process layout", selection: $flat) {
                    Text("Tree").tag(false)
                    Text("Flat List").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "\(result.count) observed" : (result.count == 1 ? "1 match" : "\(result.count) matches"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Picker("Process scope", selection: $store.scope) {
                    Text("All Processes").tag(ProcessScope.all)
                    Text("My Processes").tag(ProcessScope.mine)
                    Text("Unassigned").tag(ProcessScope.unassigned)
                    if case .app(let id) = store.scope {
                        Text(store.inventory?.value.apps.first { $0.id == id }?.name ?? "Selected App")
                            .tag(ProcessScope.app(id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 165)
                .fixedSize(horizontal: false, vertical: true)
                if case .app = store.scope {
                    Button("Clear Scope") { store.scope = .all }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            Table(result.rows, selection: $store.processSelection, sortOrder: $sort) {
                TableColumn("Process", sortUsing: KeyPathComparator(\ProcessRow.name)) { row in
                    processCell(row)
                }.width(min: 155, ideal: 280)
                TableColumn("PID", sortUsing: KeyPathComparator(\ProcessRow.pid)) { row in
                    Text(row.pid.formatted(.number.grouping(.never))).monospacedDigit()
                }.width(min: 48, ideal: 58)
                TableColumn("Footprint", sortUsing: KeyPathComparator(\ProcessRow.bytes)) { row in
                    Text(row.process.footprint?.formatted ?? "Unavailable").monospacedDigit()
                }.width(min: 77, ideal: 105)
            }
            .accessibilityIdentifier("processes-table")
            .overlay {
                if result.rows.isEmpty {
                    let searching = !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    InspectorEmpty(title: searching ? "No matching processes" : "No processes in this scope",
                                   icon: searching ? "magnifyingglass" : "list.bullet.indent",
                                   description: searching ? "Try another name, executable or PID." : "Choose a different scope or refresh the inventory.",
                                   clear: searching ? { store.query = "" } : nil)
                }
            }
        }
        .onChange(of: store.query) { _, _ in clearHiddenSelection() }
        .onChange(of: store.scope) { _, _ in clearHiddenSelection() }
        .onChange(of: flat) { _, _ in clearHiddenSelection() }
        .onChange(of: store.processSelection, initial: true) { _, selection in reveal(selection) }
        .onChange(of: store.inventory?.at) { _, _ in
            guard let keys = store.inventory?.value.records.keys else { return }
            expanded.formIntersection(keys)
            collapsed.formIntersection(keys)
        }
    }

    private func clearHiddenSelection() {
        if let selected = store.processSelection, !rows.rows.contains(where: { $0.id == selected }) {
            store.processSelection = nil
        }
    }

    private func reveal(_ id: ProcessID?) {
        guard let id, let inventory = store.inventory?.value else { return }
        var parent = inventory.parents[id]
        while let key = parent {
            expanded.insert(key)
            collapsed.remove(key)
            parent = inventory.parents[key]
        }
    }

    private func processCell(_ row: ProcessRow) -> some View {
        HStack(spacing: 4) {
            if !flat {
                Color.clear.frame(width: CGFloat(min(row.depth, 7) * 13), height: 1)
                    .accessibilityHidden(true)
                if row.expandable && store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let open = isExpanded(row)
                    Button {
                        if open { collapsed.insert(row.id); expanded.remove(row.id) }
                        else { expanded.insert(row.id); collapsed.remove(row.id) }
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(open ? "Collapse" : "Expand") \(row.name)")
                } else { Color.clear.frame(width: 16, height: 1).accessibilityHidden(true) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text(row.context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .help(row.process.path ?? "Executable unavailable")
    }

    private func isExpanded(_ row: ProcessRow) -> Bool {
        !collapsed.contains(row.id) && (expanded.contains(row.id) || row.pid == 1)
    }

    private var rows: (rows: [ProcessRow], count: Int) {
        guard let inventory = store.inventory?.value else { return ([], 0) }
        let query = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = inventory.records.filter { id, row in
            switch store.scope {
            case .all: true
            case .mine: row.uid == store.policy.user
            case .unassigned: inventory.attribution[id] == nil
            case .app(let app): inventory.attribution[id] == app
            }
        }
        let matching = scoped.filter { _, row in
            query.isEmpty || [row.name, row.path, String(row.pid)].compactMap { $0 }.contains {
                $0.localizedStandardContains(query)
            }
        }
        var ids = Set(matching.keys)
        if !flat && !query.isEmpty {
            for id in matching.keys {
                var parent = inventory.parents[id]
                while let key = parent, scoped[key] != nil, ids.insert(key).inserted {
                    parent = inventory.parents[key]
                }
            }
        }

        var root: [ProcessID] = []
        var byParent: [ProcessID: [ProcessID]] = [:]
        for id in ids {
            if !flat, let parent = inventory.parents[id], ids.contains(parent) {
                byParent[parent, default: []].append(id)
            } else { root.append(id) }
        }

        func sorted(_ ids: [ProcessID], depth: Int) -> [ProcessRow] {
            ids.compactMap { id in
                scoped[id].map { ProcessRow(process: $0, context: inventory.context(for: $0),
                                            depth: depth, expandable: byParent[id] != nil) }
            }.sorted { a, b in
                for key in sort {
                    if key.keyPath == \ProcessRow.bytes, (a.bytes == nil) != (b.bytes == nil) { return a.bytes != nil }
                    let order = key.compare(a, b)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                return a.pid < b.pid
            }
        }

        var result: [ProcessRow] = []
        var stack = Array(sorted(root, depth: 0).reversed())
        while let row = stack.popLast() {
            result.append(row)
            if let children = byParent[row.id], !query.isEmpty || isExpanded(row) {
                stack.append(contentsOf: sorted(children, depth: row.depth + 1).reversed())
            }
        }
        return (result, matching.count)
    }
}
