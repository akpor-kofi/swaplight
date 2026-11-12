import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var clearing = false

    var body: some View {
        Form {
            Section("Keep Running") {
                if store.protections.isEmpty {
                    Text("No protected apps or executables. Select an item in Apps or Processes to add it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.protections) { rule in
                    LabeledContent {
                        Button("Remove") { store.toggleProtection(rule) }
                            .accessibilityLabel("Remove Keep Running for \(rule.label)")
                    } label: {
                        Text(rule.label)
                        Text(rule.bundlePath == nil ? "All instances of this executable" : "App and its observed helpers")
                    }
                }
                Text("Protected items remain visible and are excluded from suggestions and stop requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preferences") {
                Toggle("Launch at login", isOn: Binding(get: {
                    store.loginStatus == .enabled || store.loginStatus == .requiresApproval
                }, set: { value in store.setLogin(value) }))
                if store.loginStatus == .requiresApproval {
                    LabeledContent("Waiting for approval") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                } else if store.loginStatus == .notFound {
                    Text("macOS couldn’t find the login item. Try running Swaplight from Applications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.loginError { Text(error).font(.caption).foregroundStyle(.secondary) }

                Toggle("Pressure notifications", isOn: Binding(get: {
                    store.notificationsEnabled && store.notificationStatus != .denied
                }, set: { value in Task { await store.setNotifications(value) } }))
                .disabled(store.notificationBusy)
                if store.notificationStatus == .denied {
                    LabeledContent("Notifications are off in macOS") {
                        Button("Open Notification Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                if let error = store.notificationError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Focus history") {
                LabeledContent("Apps observed on this Mac", value: store.focus.count.formatted())
                Button("Clear Focus History…") { clearing = true }.disabled(store.focus.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .frame(minHeight: 320, maxHeight: 650)
        .task { await store.refreshSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshSettings() }
        }
        .alert("Clear focus history?", isPresented: $clearing) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive, action: store.clearFocus)
        } message: {
            Text("Previously observed focus dates will be removed from this Mac. Keep Running is unchanged.")
        }
    }
}
