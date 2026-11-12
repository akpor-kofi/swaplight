import AppKit

@MainActor
struct Workspace: ApplicationInventory {
    var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func applications() -> [RunningApp] { NSWorkspace.shared.runningApplications.map(Self.describe) }

    static func describe(_ app: NSRunningApplication) -> RunningApp {
        RunningApp(pid: app.processIdentifier, name: app.localizedName ?? app.executableURL?.lastPathComponent ?? "Unknown app",
                   bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.standardizedFileURL.path,
                   executable: app.executableURL?.standardizedFileURL.path, launched: app.launchDate,
                   regular: app.activationPolicy == .regular)
    }
}
