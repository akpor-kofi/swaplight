import SwiftUI

struct MenuProcesses: View {
    @Environment(Store.self) private var store
    @Binding var selection: Target?
    let back: () -> Void
    let inspect: (Target) -> Void
    @State private var query = ""
    @State private var proposal: Confirmation?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let proposal {
                confirmation(proposal)
            } else if let selection {
                header("Review", action: back)
                details(selection)
            } else {
                header("Find a Process", action: back)
                search
            }
        }
        .onChange(of: store.inventoryIsFresh) { _, fresh in
            if !fresh { proposal = nil }
        }
    }

    private func header(_ title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: "chevron.left").frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back")
            Text(title).font(.headline)
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name, executable or PID", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("menu-process-search")
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !store.inventoryIsFresh {
                HStack {
                    Text(store.inventory == nil && !store.inventoryFailed ? "Reading processes…" : "Process readings need a refresh.")
                    Spacer()
                    Button("Refresh", action: store.refresh)
                }
                .foregroundStyle(.secondary)
            } else if trimmed.isEmpty {
                Text("Search your measured apps and processes. Use a PID to select a specific instance.")
                    .foregroundStyle(.secondary)
            } else {
                let matches = results(trimmed)
                if matches.isEmpty {
                    Text("No matching workloads with a measured footprint.").foregroundStyle(.secondary)
                }
                ForEach(matches.prefix(5), id: \.row.id) { target in
                    Button {
                        selection = target
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name).fontWeight(.medium).lineLimit(1)
                                Text("PID \(target.row.pid)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(target.row.footprint?.formatted ?? "Unavailable").monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Review \(target.name) · PID \(target.row.pid)")
                }
                if matches.count > 5 {
                    Text("Showing five matches. Refine by executable or PID.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func results(_ query: String) -> [Target] {
        guard let inventory = store.inventory?.value else { return [] }
        return inventory.records.values.filter { row in
            inventory.matches(row, query: query) && inventory.isReviewable(row, policy: store.policy)
        }.sorted { first, second in
            func exact(_ row: ProcessRecord) -> Bool {
                let name = inventory.regularAppsByPID[row.pid]?.name ?? row.name
                return name.localizedCaseInsensitiveCompare(query) == .orderedSame
            }
            if exact(first) != exact(second) { return exact(first) }
            let names = first.name.localizedStandardCompare(second.name)
            if names != .orderedSame { return names == .orderedAscending }
            return first.pid < second.pid
        }.compactMap { store.menuTarget(for: $0.id) }
    }

    private func details(_ original: Target) -> some View {
        let current = store.menuTarget(for: original.row.id)
        let target = current.flatMap { original.sameIdentity(as: $0) ? $0 : nil }
        let status = store.outcome.flatMap { $0.target.sameIdentity(as: original) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(original.name).font(.title3.weight(.semibold)).lineLimit(2)
                Text("PID \(original.row.pid) · \(original.app == nil ? "Single process" : "App")")
                    .foregroundStyle(.secondary).monospacedDigit()
                if let inventory = store.inventory?.value, let target {
                    let footprint = target.app == nil ? target.row.footprint?.formatted
                        : inventory.regularAppsByPID[target.row.pid]?.footprint.formatted
                    if let footprint { LabeledContent("Footprint", value: footprint).monospacedDigit() }
                    if let parent = inventory.parents[target.row.id].flatMap({ inventory.records[$0] }) {
                        Text("Observed parent: \(parent.name)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            if let status {
                HStack(alignment: .top) {
                    if status.outcome == .waiting { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.outcome.message)
                        if status.replacement { Text("A possible replacement appeared under the same parent.") }
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .onChange(of: status.outcome) { _, outcome in
                    AccessibilityNotification.Announcement(outcome.message).post()
                }
            }

            if let target {
                Divider()
                if let issue = store.issue(target) {
                    Label(issue, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                } else if store.canForce(target) {
                    Button("Review Force Stop…") { request(.force, target) }
                } else if status?.outcome != .exited && status?.outcome != .alreadyGone && status?.outcome != .replaced {
                    let operation: ProcessOperation = target.app == nil ? .stop : .quit
                    Button(operation.rawValue + "…", role: .destructive) { request(operation, target) }
                        .disabled(store.actionWaiting)
                }
                Button("Open in Inspector") { inspect(target) }
                    .buttonStyle(.borderless)
            } else if status == nil || status?.outcome == .cancelled {
                Text("This process is no longer verified. Search again to review a current process.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func request(_ operation: ProcessOperation, _ target: Target) {
        proposal = store.review(operation, target: target)
    }

    private func confirmation(_ request: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            Text(request.message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    proposal = nil
                    store.cancel(request)
                }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
                Button(request.operation.rawValue, role: .destructive) {
                    proposal = nil
                    Task { await store.confirm(request) }
                }
            }
        }
    }
}
