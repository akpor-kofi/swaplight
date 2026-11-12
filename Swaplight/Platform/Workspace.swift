import AppKit
import Darwin

@MainActor
struct Workspace: ApplicationInventory {
    var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func applications() -> [RunningApp] { NSWorkspace.shared.runningApplications.map(Self.describe) }

    static func describe(_ app: NSRunningApplication) -> RunningApp {
        let executable = app.executableURL?.standardizedFileURL
        let launched = app.launchDate
        let identity = launched == nil ? kernelIdentity(for: app, executable: executable?.path) : nil
        return RunningApp(pid: app.processIdentifier, name: app.localizedName ?? executable?.lastPathComponent ?? "Unknown app",
                          bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.standardizedFileURL.path,
                          executable: executable?.path, launched: launched, regular: app.activationPolicy == .regular,
                          kernelIdentity: identity)
    }

    private static func kernelIdentity(for app: NSRunningApplication, executable: String?) -> KernelAppIdentity? {
        let pid = app.processIdentifier
        guard pid > 1, let executable, !app.isTerminated,
              let before = Kernel.bsd(pid).0, before.pbi_status != SZOMB,
              let start = DarwinSampler.start(before), Kernel.path(pid) == executable,
              let after = Kernel.bsd(pid).0, after.pbi_status != SZOMB,
              DarwinSampler.start(after) == start, before.pbi_uid == after.pbi_uid,
              !app.isTerminated else { return nil }
        return KernelAppIdentity(start: start, uid: after.pbi_uid)
    }
}
