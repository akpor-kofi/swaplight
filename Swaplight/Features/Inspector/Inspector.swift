import SwiftUI

struct Inspector: View {
    @Environment(Store.self) private var store
    @State private var details = true

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: Binding<InspectorPage?>(get: { store.page }, set: { page in
                if let page, page != store.page {
                    store.query = ""
                    store.page = page
                }
            })) {
                Section("Monitor") {
                    ForEach(InspectorPage.allCases) { page in
                        Label(page.rawValue, systemImage: page.symbol).tag(page)
                    }
                }
                Section("Preferences") {
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 125, ideal: 155, max: 205)
        } detail: {
            VStack(spacing: 0) {
                if let status = store.outcome {
                    outcome(status)
                    Divider()
                }
                if store.page != .overview, !store.inventoryIsFresh { freshness }
                switch store.page {
                case .overview: Overview(popover: false)
                case .apps: AppsTable()
                case .processes: ProcessesTable()
                }
            }
            .navigationTitle(store.page.rawValue)
            .searchable(text: $store.query, placement: .toolbar, prompt: store.page == .apps ? "Search apps" : "Name, executable or PID")
            .toolbar {
                ToolbarItemGroup {
                    Button(action: store.refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.help("Refresh readings")
                    Button {
                        details.toggle()
                    } label: {
                        Label("Details", systemImage: "sidebar.trailing")
                    }.help("Show or hide details")
                }
            }
            .inspector(isPresented: $details) {
                Details()
                    .inspectorColumnWidth(min: 225, ideal: 275, max: 380)
            }
        }
        .onAppear { store.setVisible("inspector", true) }
        .onDisappear {
            store.setVisible("inspector", false)
            store.confirmation = nil
        }
        .alert(store.confirmation.map { "\($0.operation.rawValue): \($0.target.name)?" } ?? "Process action",
               isPresented: Binding(get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }),
               presenting: store.confirmation) { proposal in
            Button("Cancel", role: .cancel) { store.cancel(proposal) }.keyboardShortcut(.defaultAction)
            Button(proposal.operation.rawValue, role: .destructive) {
                Task { await store.confirm(proposal) }
            }
        } message: { proposal in
            Text(confirmationMessage(proposal))
        }
    }

    private var freshness: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                if let sample = store.inventory {
                    let seconds = max(0, sample.at.duration(to: store.currentTime).components.seconds)
                    let age = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
                    Label("Process data is stale · Last updated \(age)", systemImage: "clock")
                } else if store.inventoryFailed {
                    Label("Process inventory is unavailable", systemImage: "exclamationmark.circle")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Reading processes…")
                }
                Spacer()
                Button("Retry", action: store.refresh).controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func outcome(_ status: ActionStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if status.outcome == .waiting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.outcome == .exited ? "checkmark.circle" : "info.circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(status.target.name) · PID \(status.target.row.pid)").fontWeight(.medium)
                Text(status.outcome.message).foregroundStyle(.secondary)
                if status.replacement {
                    Text("A possible replacement appeared under the same parent. Review it in Processes.")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("action-outcome")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: status.outcome) { _, value in
            AccessibilityNotification.Announcement(value.message).post()
        }
    }

    private func confirmationMessage(_ proposal: Confirmation) -> String {
        let pid = proposal.target.row.pid
        switch proposal.operation {
        case .quit:
            return "PID \(pid). The app can ask you to save work before it quits. Work running inside the app may be interrupted."
        case .stop:
            return "PID \(pid). \(proposal.context)Only this process will receive a stop request. Its parent and siblings won’t be signaled. Work may be interrupted, and a watcher may restart the process."
        case .force:
            let scope = proposal.target.app == nil ? "Only PID \(pid) will receive a force stop request."
                : "This will force quit the app at PID \(pid)."
            return "\(scope) Unsaved work may be lost."
        }
    }
}

struct InspectorEmpty: View {
    let title: String
    let icon: String
    let description: String
    var clear: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(description)
        } actions: {
            if let clear { Button("Clear Search", action: clear) }
        }
    }
}
