import Darwin
import Foundation

struct DarwinSampler: MemorySampling, ProcessSampling {
    func sampleMemory() async -> HostMemory {
        await Task.detached(priority: .utility) {
            let vm = Kernel.vm()
            return HostMemory(total: Bytes(ProcessInfo.processInfo.physicalMemory),
                              occupied: vm.map { Bytes($0.occupied) }, compressed: vm.map { Bytes($0.compressed) },
                              swap: Kernel.swap().map(Bytes.init))
        }.value
    }

    func sampleProcesses() async -> [ProcessRecord]? {
        await Task.detached(priority: .utility) {
            guard let pids = Kernel.pids() else { return nil }
            return pids.compactMap { pid in
                let (bsd, error) = Kernel.bsd(pid)
                guard let bsd, let start = Self.start(bsd) else {
                    if error == ESRCH { return nil }
                    return Self.record(pid, bsd: nil, path: Kernel.path(pid))
                }
                let path = Kernel.path(pid)
                let usage = Kernel.usage(pid)
                // Inventory changes during the scan. Don't mix readings from reused PIDs.
                guard let next = Kernel.bsd(pid).0, Self.start(next) == start, next.pbi_uid == bsd.pbi_uid,
                      next.pbi_ppid == bsd.pbi_ppid else { return nil }
                return Self.record(pid, bsd: next, path: path, usage: usage)
            }
        }.value
    }

    static func start(_ bsd: proc_bsdinfo) -> Start? {
        guard bsd.pbi_start_tvsec > 0, bsd.pbi_start_tvusec < 1_000_000 else { return nil }
        return Start(seconds: bsd.pbi_start_tvsec, microseconds: bsd.pbi_start_tvusec)
    }

    static func record(_ pid: Int32, bsd: proc_bsdinfo?, path: String?,
                       usage: rusage_info_v4? = nil) -> ProcessRecord {
        var name = ""
        if var raw = bsd?.pbi_name {
            name = withUnsafeBytes(of: &raw) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return ProcessRecord(id: ProcessID(pid: pid, start: bsd.flatMap(start)),
                             name: path.map { URL(fileURLWithPath: $0).lastPathComponent }
                                 ?? (bsd == nil || name.isEmpty ? "PID \(pid)" : name),
                             path: path, uid: bsd?.pbi_uid, parentPID: bsd.map { Int32($0.pbi_ppid) },
                             terminal: bsd?.e_tdev, footprint: usage.map { Bytes($0.ri_phys_footprint) },
                             resident: usage.map { Bytes($0.ri_resident_size) },
                             cpuTime: usage.map { $0.ri_user_time + $0.ri_system_time },
                             diskRead: usage?.ri_diskio_bytesread, diskWritten: usage?.ri_diskio_byteswritten)
    }
}
