import Foundation
import Darwin

struct MachineInfo: Codable, Hashable {
    var chip: String
    var ramGB: Double
    var os: String
}

enum SystemInfo {
    static let machine: MachineInfo = {
        MachineInfo(chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
                    ramGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                    os: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    }()

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Memory in use system-wide, the way Activity Monitor computes "Memory Used":
    /// app memory (internal - purgeable) + wired + compressed.
    static func usedMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// Physical footprint of a process (includes Metal/unified memory buffers).
    static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : 0
    }

    static func children(_ pid: pid_t) -> [pid_t] {
        let n = proc_listchildpids(pid, nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) * 2 + 8)
        let m = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard m > 0 else { return [] }
        return Array(buf.prefix(Int(m))).filter { $0 > 0 }
    }

    /// The process and all of its descendants.
    static func processTree(_ pid: pid_t) -> [pid_t] {
        var result: [pid_t] = [pid]
        var queue: [pid_t] = [pid]
        while let p = queue.popLast() {
            for c in children(p) where !result.contains(c) {
                result.append(c)
                queue.append(c)
            }
        }
        return result
    }

    static func treeFootprint(_ pid: pid_t) -> UInt64 {
        processTree(pid).reduce(0) { $0 + footprint($1) }
    }

    static func isPortFree(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    static func freePort(from start: Int) -> Int {
        var p = start
        while p < start + 500 {
            if isPortFree(p) { return p }
            p += 1
        }
        return start
    }
}

/// Samples memory while an engine runs and keeps the peak values.
final class MemoryMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var peakSystem: UInt64 = 0
    private var peakProcess: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var pid: pid_t?
    let baseline: UInt64

    init() {
        let samples = (0..<3).map { _ -> UInt64 in
            let v = SystemInfo.usedMemoryBytes()
            usleep(100_000)
            return v
        }
        baseline = samples.sorted()[1]
    }

    func start(pid: pid_t?) {
        self.pid = pid
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let sys = SystemInfo.usedMemoryBytes()
        let proc = pid.map { SystemInfo.treeFootprint($0) } ?? 0
        lock.lock()
        peakSystem = max(peakSystem, sys)
        peakProcess = max(peakProcess, proc)
        lock.unlock()
    }

    /// Peak memory added since the baseline (GB) and peak process-tree footprint (GB).
    func snapshot() -> (systemDeltaGB: Double, processGB: Double) {
        sample()
        lock.lock(); defer { lock.unlock() }
        let delta = peakSystem > baseline ? peakSystem - baseline : 0
        return (Double(delta) / 1_073_741_824, Double(peakProcess) / 1_073_741_824)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
