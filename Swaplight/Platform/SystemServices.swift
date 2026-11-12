import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class WorkspaceEvents {
    private var tokens: [any NSObjectProtocol] = []
    private let center = NSWorkspace.shared.notificationCenter

    func start(activation: @escaping @MainActor (RunningApp) -> Void,
               sleep: @escaping @MainActor (Bool) -> Void) {
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { activation(Workspace.describe(app)) }
            }
        })
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sleep(sleeping) }
            })
        }
    }
}

@MainActor
final class SystemServices {
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    func observePressure(_ receive: @escaping @MainActor (Pressure) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let data = self?.pressureSource?.data else { return }
                if data.contains(.critical) { receive(.critical) }
                else if data.contains(.warning) { receive(.elevated) }
                else if data.contains(.normal) { receive(.normal) }
            }
        }
        pressureSource = source
        source.activate()
    }

    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    func setLogin(_ value: Bool) throws {
        if value { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func authorizeNotifications() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    func notify(_ pressure: Pressure) async {
        let content = UNMutableNotificationContent()
        content.title = "Memory pressure: \(pressure.rawValue)"
        content.body = "Open Swaplight to review memory usage."
        let request = UNNotificationRequest(identifier: "swaplight-pressure", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
