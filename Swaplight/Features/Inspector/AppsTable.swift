import SwiftUI

private struct AppRow: Identifiable {
    let group: AppGroup
    let lastFocus: Date?
    let protected: Bool
    let frontmost: Bool
    var id: ProcessID { group.id }
    var name: String { group.name }
    var bytes: UInt64? { group.footprint.known?.value }
    var count: Int? { group.main.id.start == nil ? nil : group.count }
}

struct AppsTable: View {
    @Environment(Store.self) private var store
    @State private var sort = [KeyPathComparator(\AppRow.bytes, order: .reverse)]

    var body: some View {
        @Bindable var store = store
        let rows = rows
        Table(rows, selection: $store.appSelection, sortOrder: $sort) {
            TableColumn("Application", sortUsing: KeyPathComparator(\AppRow.name)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).lineLimit(1)
                    if row.protected || row.frontmost {
                        Text(row.protected ? "Keep Running" : "Frontmost")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }.width(min: 100, ideal: 170)
            TableColumn("Footprint", sortUsing: KeyPathComparator(\AppRow.bytes)) { row in
                Text(row.group.footprint.formatted).monospacedDigit()
            }.width(min: 76, ideal: 105)
            TableColumn("Observed", sortUsing: KeyPathComparator(\AppRow.count)) { row in
                Text(row.count?.formatted() ?? "—").monospacedDigit()
                    .accessibilityLabel(row.count.map { "\($0) observed processes" } ?? "Observed count unavailable")
            }.width(min: 60, ideal: 75)
            TableColumn("Last Focus", sortUsing: KeyPathComparator(\AppRow.lastFocus)) { row in
                Text(row.lastFocus?.formatted(.relative(presentation: .named)) ?? "Not observed")
                    .lineLimit(1)
                    .help(row.lastFocus?.formatted(date: .abbreviated, time: .standard) ?? "Not observed")
            }.width(min: 84, ideal: 115)
        }
        .accessibilityIdentifier("apps-table")
        .onChange(of: store.query) { _, _ in
            if let selected = store.appSelection, !self.rows.contains(where: { $0.id == selected }) {
                store.appSelection = nil
            }
        }
        .overlay {
            if rows.isEmpty {
                let searching = !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                InspectorEmpty(title: searching ? "No matching apps" : "No apps to show",
                               icon: searching ? "magnifyingglass" : "square.grid.2x2",
                               description: searching ? "Try another name, bundle identifier or PID. Only apps with a measured footprint are listed."
                                   : "Apps appear here when Swaplight can read their footprint and verify their identity.",
                               clear: searching ? { store.query = "" } : nil)
            }
        }
    }

    private var rows: [AppRow] {
        guard let snapshot = store.inventory?.value else { return [] }
        let query = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.apps.filter { group in
            snapshot.isReviewable(group, policy: store.policy)
                && (query.isEmpty || [group.name, group.app.bundleID, String(group.main.pid)]
                    .compactMap { $0 }.contains { $0.localizedStandardContains(query) })
        }.map { group in
            AppRow(group: group, lastFocus: group.app.bundleID.flatMap { store.focus[$0] },
                   protected: store.policy.isProtected(row: group.main, app: group.app, ancestry: [], protections: store.protections),
                   frontmost: group.main.pid == store.frontmost)
        }.sorted { a, b in
            for key in sort {
                if key.keyPath == \AppRow.lastFocus, (a.lastFocus == nil) != (b.lastFocus == nil) { return a.lastFocus != nil }
                if key.keyPath == \AppRow.bytes, (a.bytes == nil) != (b.bytes == nil) { return a.bytes != nil }
                if key.keyPath == \AppRow.count, (a.count == nil) != (b.count == nil) { return a.count != nil }
                let order = key.compare(a, b)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.id.pid < b.id.pid
        }
    }
}
