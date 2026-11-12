import Darwin
import Foundation

enum Kernel {
    struct VM: Sendable {
        let pageSize: UInt64
        let active, inactive, wired, speculative, purgeable, external, compressor: UInt64

        // Active/inactive can include clean file cache and purgeable pages.
        // This is a host estimate; compressed pages are already included in it.
        var occupied: UInt64 {
            let used = active + inactive + speculative + wired + compressor
            let reclaimable = external + purgeable
            return (used > reclaimable ? used - reclaimable : 0) * pageSize
        }
        var compressed: UInt64 { compressor * pageSize }
    }

    static func vm() -> VM? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var raw = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &raw) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == capacity else { return nil }
        return VM(pageSize: UInt64(pageSize), active: UInt64(raw.active_count),
                  inactive: UInt64(raw.inactive_count), wired: UInt64(raw.wire_count),
                  speculative: UInt64(raw.speculative_count), purgeable: UInt64(raw.purgeable_count),
                  external: UInt64(raw.external_page_count), compressor: UInt64(raw.compressor_page_count))
    }

    static func swap() -> UInt64? {
        var raw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &raw, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return nil }
        return raw.xsu_used
    }

    static func pids() -> [pid_t]? {
        let estimate = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        var capacity = estimate / stride + 256
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let read = pids.withUnsafeMutableBytes {
                Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)))
            }
            guard read > 0 else { return nil }
            if read < capacity * stride { return Array(Set(pids.prefix(read / stride).filter { $0 > 0 })).sorted() }
            capacity *= 2
        }
        return nil
    }

    static func bsd(_ pid: pid_t) -> (proc_bsdinfo?, Int32) {
        var raw = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &raw, size)
        return result == size ? (raw, 0) : (nil, errno)
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var raw = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &raw) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? raw : nil
    }
}
