import SwiftUI

struct Overview: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var reviewOrder: [ProcessID] = []
    let popover: Bool
    var visibilityKey = "popover"

    var body: some View {
        Group {
            if popover {
                content.frame(width: 316).padding(14)
            } else {
                ScrollView { content.frame(maxWidth: 520, alignment: .leading).padding(24) }
            }
        }
        .onAppear {
            reviewOrder = store.candidates.map(\.id)
            if popover { store.setVisible(visibilityKey, true) }
        }
        .onDisappear { if popover { store.setVisible(visibilityKey, false) } }
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
            Text("Suggested to review").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if !store.inventoryIsFresh {
                Text(store.inventory == nil && !store.inventoryFailed
                     ? "Reading processes…" : "Suggestions need a fresh process sample.")
                    .foregroundStyle(.secondary)
            } else if store.candidates.isEmpty {
                Text("No apps suggested to quit right now.").foregroundStyle(.secondary)
            } else {
                let candidates = store.candidates.sorted {
                    (reviewOrder.firstIndex(of: $0.id) ?? Int.max) < (reviewOrder.firstIndex(of: $1.id) ?? Int.max)
                }
                ForEach(candidates.prefix(3)) { row in
                    Button {
                        show(row.app ? .apps : .processes, selection: row.id)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).fontWeight(.medium).lineLimit(1)
                                Text(row.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(row.footprint.formatted).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Review \(row.name), \(row.reason), \(row.footprint.formatted)")
                }
            }
            Divider()
            HStack {
                Button("All Apps") { show(.apps) }
                Button("All Processes") { show(.processes) }
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

    private func show(_ page: InspectorPage, selection: ProcessID? = nil) {
        store.navigate(page, selection: selection)
        if popover {
            NSApp.activate()
            openWindow(id: "inspector")
        }
    }
}
