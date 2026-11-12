import Darwin
import Foundation

@main
enum Feasibility {
    static func main() {
        let clock = ContinuousClock()
        let start = clock.now
        let pids = Kernel.pids() ?? []
        var metadata = 0, footprint = 0, parentLinks = 0, paths = 0
        let observed = Set(pids)
        for pid in pids {
            if let bsd = Kernel.bsd(pid).0, bsd.pbi_start_tvsec > 0 {
                metadata += 1
                if observed.contains(pid_t(bsd.pbi_ppid)) { parentLinks += 1 }
            }
            if Kernel.usage(pid) != nil { footprint += 1 }
            if Kernel.path(pid) != nil { paths += 1 }
        }
        let elapsed = start.duration(to: clock.now)
        let vm = Kernel.vm()
        print("page size: \(vm?.pageSize.description ?? "unavailable")")
        print("RAM total / estimated / compressed, bytes: \(ProcessInfo.processInfo.physicalMemory) / \(vm?.occupied.description ?? "unavailable") / \(vm?.compressed.description ?? "unavailable")")
        print("swap used, bytes: \(Kernel.swap()?.description ?? "unavailable")")
        print("aggregate inventory: \(pids.count) PIDs, \(metadata) start identities, \(parentLinks) observed parent candidates, \(footprint) resource records, \(paths) executable paths; \(elapsed)")
        // A bounded workload in this probe only. Do not drive the host into pressure.
        let size = 96 * 1_024 * 1_024
        let prior = Kernel.usage(getpid())?.ri_phys_footprint
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { allocation.deallocate() }
        memset(allocation, 1, size)
        if let prior, let during = Kernel.usage(getpid())?.ri_phys_footprint, during >= prior {
            print("footprint grew by \(during - prior) bytes for a 96 MiB allocation")
        }
        if let vm = Kernel.vm() { print("loaded RAM estimate / compressed: \(vm.occupied) / \(vm.compressed)") }
        // Wait for natural exit. The probe never sends a signal.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["1"]
        do {
            try child.run()
            defer { child.waitUntilExit() }
            let first = Kernel.bsd(child.processIdentifier).0
            let next = Kernel.bsd(child.processIdentifier).0
            print("read-only child: observed parent = \(first?.pbi_ppid == UInt32(getpid())), stable start = \(first != nil && first?.pbi_start_tvsec == next?.pbi_start_tvsec && first?.pbi_start_tvusec == next?.pbi_start_tvusec)")
        } catch { print("Could not launch read-only child: \(error.localizedDescription)") }
    }
}
