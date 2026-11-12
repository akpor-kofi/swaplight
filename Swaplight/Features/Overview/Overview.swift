import SwiftUI

struct Overview: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var reviewOrder: [ProcessID] = []
    @State private var findingProcess = false
    @State private var menuSelection: Target?
    let popover: Bool
    var visibilityKey = "popover"

    var body: some View {
        Group {
            if popover {
                Group {
                    if findingProcess || menuSelection != nil {
                        MenuProcesses(selection: $menuSelection, back: goBack, inspect: inspect)
                    } else {
                        content
                    }
                }
                .frame(width: 316, alignment: .leading)
                .padding(14)
            } else {
                ScrollView { content.frame(maxWidth: 520, alignment: .leading).padding(24) }
            }
        }
        .onAppear {
            reviewOrder = store.candidates.map(\.id)
            if popover { store.setVisible(visibilityKey, true) }
        }
        .onDisappear {
            if popover {
                store.setVisible(visibilityKey, false)
                findingProcess = false
                menuSelection = nil
            }
        }
        .onChange(of: store.candidates.map(\.id), initial: true) { _, ids in
            if popover {
                reviewOrder = reviewOrder.filter { ids.contains($0) } + ids.filter { !reviewOrder.contains($0) }
            }
            else { reviewOrder = ids }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if popover {
                HStack {
                    Label { Text("Swaplight").font(.headline) } icon: {
                        Image(.menuMark).renderingMode(.template)
                    }
                    Spacer()
                    Button {
                        NSApp.activate()
                        openSettings()
                    } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Settings")
                        .accessibilityLabel("Settings")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Memory pressure")
                        Spacer()
                        Label(store.pressure.rawValue, systemImage: store.pressure.symbol)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(pressureColor)
                            .accessibilityLabel("Memory pressure: \(store.pressure.rawValue)")
                    }
                    HStack(spacing: 12) {
                        metric("RAM", store.memory?.value.occupied?.formatted, subtitle: ramSubtitle)
                        Divider().frame(height: 38)
                        metric("Swap", store.swap?.value.formatted, subtitle: store.swapIsStale ? "Last reading on disk" : "Used on disk")
                    }
                    HStack(alignment: .top) {
                        Text("Compressed: \(store.memory?.value.compressed?.formatted ?? "Unavailable")")
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Text(sampleStatus).multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if store.memoryIsStale || store.swapIsStale {
                        HStack {
                            Text("Some readings couldn’t refresh.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry", action: store.refresh).controlSize(.small)
                        }
                    }
                }
            }
            Divider()
            if let app = store.activeApp {
                reviewRow(id: app.id, name: app.name,
                          reason: store.frontmost == app.main.pid ? "In use" : "Last active",
                          footprint: app.footprint, page: .apps)
                Divider()
            }
            Text("Suggested to review").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if !store.inventoryIsFresh {
                Text(store.inventory == nil && !store.inventoryFailed
                     ? "Reading processes…" : "Suggestions need a fresh process sample.")
                    .foregroundStyle(.secondary)
            } else if store.candidates.isEmpty {
                Text("No workloads suggested right now.").foregroundStyle(.secondary)
            } else {
                let candidates = store.candidates.sorted {
                    (reviewOrder.firstIndex(of: $0.id) ?? Int.max) < (reviewOrder.firstIndex(of: $1.id) ?? Int.max)
                }
                ForEach(candidates.prefix(5)) { row in
                    reviewRow(id: row.id, name: row.name, reason: row.reason,
                              footprint: row.footprint, page: row.app ? .apps : .processes)
                }
            }
            Divider()
            if popover {
                Button {
                    findingProcess = true
                } label: {
                    Label("Find a Process…", systemImage: "magnifyingglass")
                }
                if let status = store.outcome {
                    Button {
                        menuSelection = status.target
                    } label: {
                        Label("Last action: \(status.target.name)", systemImage: "clock")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Apps Inspector") { show(.apps) }
                Button("Processes Inspector") { show(.processes) }
                Spacer()
                if popover {
                    Menu {
                        Button("Refresh", action: store.refresh)
                        Button("Quit Swaplight") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Swaplight commands")
                }
            }
        }
        .accessibilityIdentifier(popover ? "menu-overview" : "inspector-overview")
    }

    private func reviewRow(id: ProcessID, name: String, reason: String, footprint: Footprint,
                           page: InspectorPage) -> some View {
        Button {
            if popover { menuSelection = store.menuTarget(for: id) }
            else { show(page, selection: id) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).fontWeight(.medium).lineLimit(1)
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(footprint.formatted).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review \(name), \(reason), \(footprint.formatted)")
    }

    private func metric(_ name: String, _ value: String?, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value ?? (store.memory == nil ? "—" : "Unavailable"))
                .font(value == nil ? .title3 : .title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var pressureColor: Color {
        switch store.pressure {
        case .unknown, .normal: .secondary
        case .elevated: .orange
        case .critical: .red
        }
    }

    private var ramSubtitle: String {
        guard let total = store.memory?.value.total.formatted else { return "Occupied estimate" }
        return "Est. occupied · \(total) total"
    }

    private var sampleStatus: String {
        guard let memory = store.memory else { return "Reading memory…" }
        let oldest = min(memory.at, store.swap?.at ?? memory.at)
        let seconds = max(0, oldest.duration(to: store.currentTime).components.seconds)
        let age = seconds < 5 ? "just now" : seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
        return store.memoryIsStale || store.swapIsStale ? "Last sample \(age)" : "Updated \(age)"
    }

    private func goBack() {
        if menuSelection != nil { menuSelection = nil }
        else { findingProcess = false }
    }

    private func inspect(_ target: Target) {
        let app = store.inventory?.value.regularAppsByPID[target.row.pid]
        let hasAppRow = app.map { store.inventory?.value.isReviewable($0, policy: store.policy) == true } ?? false
        show(hasAppRow ? .apps : .processes, selection: target.row.id)
    }

    private func show(_ page: InspectorPage, selection: ProcessID? = nil) {
        store.navigate(page, selection: selection)
        if popover {
            NSApp.activate()
            openWindow(id: "inspector")
        }
    }
}
