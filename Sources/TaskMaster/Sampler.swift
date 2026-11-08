import Foundation
import Darwin
import IOKit
import SystemConfiguration
import CoreWLAN
import Metal

private let timebase: (num: UInt64, den: UInt64) = {
    var i = mach_timebase_info_data_t()
    mach_timebase_info(&i)
    return (UInt64(i.numer), UInt64(i.denom))
}()

private func machToNs(_ t: UInt64) -> UInt64 { t * timebase.num / timebase.den }

actor Sampler {
    private struct Prev { var start: Int64; var cpuNs: UInt64; var disk: UInt64; var energy: UInt64 }
    private struct RawDisk { var reads: UInt64; var writes: UInt64; var rOps: UInt64; var wOps: UInt64; var rTime: UInt64; var wTime: UInt64 }

    private let ncpu = ProcessInfo.processInfo.processorCount
    private var prevProcs: [Int32: Prev] = [:]
    private var prevTime: UInt64 = 0
    private var prevTicks: [[UInt32]] = []
    private var prevDisks: [UInt64: RawDisk] = [:]
    private var prevNets: [String: (UInt64, UInt64)] = [:]
    private var prevGPU: [Int32: UInt64] = [:]
    private var pathCache: [Int32: (Int64, String)] = [:]
    private let netTop = NetTopStream()
    private let top = TopStream()
    private let gpuName: String = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"

    func stop() { netTop.stop(); top.stop() }

    func sample() -> Snapshot {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let dt = prevTime == 0 ? 1.0 : max(Double(now - prevTime) / 1e9, 0.05)
        let first = prevTime == 0
        prevTime = now

        var snap = Snapshot()
        snap.interval = dt
        snap.uptime = Date().timeIntervalSince(Sys.bootTime)
        snap.handles = Sys.int("kern.num_files") ?? 0

        sampleCPU(&snap)
        snap.mem = sampleMemory()
        snap.disks = sampleDisks(dt: dt)
        snap.nets = sampleNetworks(dt: dt)
        let gpuPerPid = sampleGPU(&snap, dt: dt)
        snap.procs = sampleProcesses(dt: dt, first: first, gpu: gpuPerPid)
        snap.threads = snap.procs.reduce(0) { $0 + $1.threads }
        return snap
    }

    // MARK: processes

    private func rusage(_ pid: Int32) -> rusage_info_current? {
        var ru = rusage_info_current()
        let r = withUnsafeMutablePointer(to: &ru) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? ru : nil
    }

    private func path(_ pid: Int32, start: Int64) -> String {
        if let c = pathCache[pid], c.0 == start { return c.1 }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, 4096)
        let p = n > 0 ? String(cString: buf) : ""
        pathCache[pid] = (start, p)
        return p
    }

    private func sampleProcesses(dt: Double, first: Bool, gpu: [Int32: Double]) -> [ProcSample] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 3, nil, &size, nil, 0)
        let cap = size / MemoryLayout<kinfo_proc>.stride + 32
        var list = [kinfo_proc](repeating: kinfo_proc(), count: cap)
        size = cap * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride

        let topData = top.latest
        let nets = netTop.latest
        var out: [ProcSample] = []
        out.reserveCapacity(n)
        var seen = Set<Int32>()

        for i in 0..<n {
            var kp = list[i]
            let pid = kp.kp_proc.p_pid
            if pid < 0 { continue }
            seen.insert(pid)
            let start = Int64(kp.kp_proc.p_starttime.tv_sec)
            let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let p = pid == 0 ? "" : path(pid, start: start)
            var s = ProcSample(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid,
                               name: p.isEmpty ? (pid == 0 ? "kernel_task" : comm) : (p as NSString).lastPathComponent,
                               path: p)
            s.suspended = kp.kp_proc.p_stat == 4
            s.translated = (kp.kp_proc.p_flag & 0x20000) != 0
            s.startTime = Date(timeIntervalSince1970: TimeInterval(start))

            if let ru = rusage(pid) {
                let cpuNs = machToNs(ru.ri_user_time + ru.ri_system_time)
                s.cpuTime = Double(cpuNs) / 1e9
                s.memory = ru.ri_phys_footprint
                let disk = ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten
                if let pv = prevProcs[pid], pv.start == start, !first {
                    let dCpu = cpuNs >= pv.cpuNs ? cpuNs - pv.cpuNs : 0
                    s.cpuDelta = Double(dCpu) / 1e9
                    s.cpu = min(100, s.cpuDelta / dt * 100 / Double(ncpu))
                    s.diskDelta = disk >= pv.disk ? disk - pv.disk : 0
                    s.diskRate = Double(s.diskDelta) / dt
                    let dE = ru.ri_energy_nj >= pv.energy ? ru.ri_energy_nj - pv.energy : 0
                    s.power = Double(dE) / 1e9 / dt
                }
                prevProcs[pid] = Prev(start: start, cpuNs: cpuNs, disk: disk, energy: ru.ri_energy_nj)
                var ti = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    s.threads = Int(ti.pti_threadnum)
                }
            } else if let t = topData[pid] {
                s.accessible = false
                s.cpu = min(100, t.cpu / Double(ncpu))
                s.memory = t.mem
                s.threads = t.threads
            } else {
                s.accessible = false
            }
            if let nr = nets[pid] {
                s.netRate = nr.down + nr.up
                s.netDelta = UInt64(s.netRate)
            }
            s.gpu = gpu[pid] ?? 0
            out.append(s)
        }
        prevProcs = prevProcs.filter { seen.contains($0.key) }
        pathCache = pathCache.filter { seen.contains($0.key) }
        return out
    }

    // MARK: CPU

    private func sampleCPU(_ snap: inout Snapshot) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        var ticks: [[UInt32]] = []
        for c in 0..<Int(count) {
            let b = c * Int(CPU_STATE_MAX)
            ticks.append([UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])])
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        if prevTicks.count == ticks.count {
            var cores: [Double] = []
            var busyAll = 0.0, totalAll = 0.0
            for c in 0..<ticks.count {
                let d = (0..<4).map { Double(ticks[c][$0] &- prevTicks[c][$0]) }
                let total = d.reduce(0, +)
                let busy = d[0] + d[1] + d[3]
                cores.append(total > 0 ? busy / total * 100 : 0)
                busyAll += busy; totalAll += total
            }
            snap.cores = cores
            snap.cpu = totalAll > 0 ? busyAll / totalAll * 100 : 0
        } else {
            snap.cores = Array(repeating: 0, count: ticks.count)
        }
        prevTicks = ticks
    }

    // MARK: memory

    private func sampleMemory() -> MemSample {
        var m = MemSample()
        m.total = UInt64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = UInt64(getpagesize())
        if r == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { m.swapUsed = sw.xsu_used; m.swapTotal = sw.xsu_total }
        m.pressure = Sys.int("kern.memorystatus_vm_pressure_level") ?? 1
        return m
    }

    // MARK: disks

    private func props(_ entry: io_registry_entry_t) -> [String: Any]? {
        var p: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return p?.takeRetainedValue() as? [String: Any]
    }

    private func sampleDisks(dt: Double) -> [DiskSample] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var found: [(id: UInt64, name: String, kind: String, cap: UInt64, raw: RawDisk)] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            guard let p = props(s), let st = p["Statistics"] as? [String: Any] else { continue }
            func u(_ k: String) -> UInt64 { (st[k] as? NSNumber)?.uint64Value ?? 0 }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &id)

            var name = "Disk", kind = "Disk", external = false
            var cur = s
            IOObjectRetain(cur)
            for _ in 0..<6 {
                if let pp = props(cur), let dc = pp["Device Characteristics"] as? [String: Any] {
                    name = (dc["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? name
                    if (dc["Medium Type"] as? String) == "Solid State" { kind = "SSD" }
                    if (pp["Physical Interconnect Location"] as? String) == "External" { external = true }
                    break
                }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(cur)
                cur = parent
            }
            IOObjectRelease(cur)
            if name.contains("Disk Image") { continue }
            if external { kind = kind == "SSD" ? "External SSD" : "External" }

            var cap: UInt64 = 0
            var ci: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(s, kIOServicePlane, &ci) == KERN_SUCCESS {
                while case let c = IOIteratorNext(ci), c != 0 {
                    if let cp = props(c), (cp["Whole"] as? Bool) == true { cap = (cp["Size"] as? NSNumber)?.uint64Value ?? 0 }
                    IOObjectRelease(c)
                }
                IOObjectRelease(ci)
            }
            found.append((id, name, kind, cap, RawDisk(reads: u("Bytes (Read)"), writes: u("Bytes (Write)"), rOps: u("Operations (Read)"),
                                                       wOps: u("Operations (Write)"), rTime: u("Total Time (Read)"), wTime: u("Total Time (Write)"))))
        }
        found.sort { $0.id < $1.id }
        var out: [DiskSample] = []
        for (i, f) in found.enumerated() {
            var d = DiskSample(id: f.id, index: i, name: f.name, kind: f.kind, capacity: f.cap)
            if let pv = prevDisks[f.id] {
                func dl(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) : 0 }
                d.readBps = dl(f.raw.reads, pv.reads) / dt
                d.writeBps = dl(f.raw.writes, pv.writes) / dt
                let t = dl(f.raw.rTime, pv.rTime) + dl(f.raw.wTime, pv.wTime)
                let ops = dl(f.raw.rOps, pv.rOps) + dl(f.raw.wOps, pv.wOps)
                d.active = min(100, t / (dt * 1e9) * 100)
                d.responseMs = ops > 0 ? t / ops / 1e6 : 0
            }
            prevDisks[f.id] = f.raw
            out.append(d)
        }
        return out
    }

    // MARK: network

    private func sampleNetworks(dt: Double) -> [NetSample] {
        var hw: [String: (String, Bool)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(i) as String?
                let wifi = type == (kSCNetworkInterfaceTypeIEEE80211 as String)
                hw[bsd] = ((SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd, wifi)
            }
        }
        var v4: [String: String] = [:], v6: [String: String] = [:], up = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0 {
            var p = ifap
            while let c = p {
                let name = String(cString: c.pointee.ifa_name)
                if (c.pointee.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING) { up.insert(name) }
                if let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let a = String(cString: host)
                    if sa.pointee.sa_family == UInt8(AF_INET) { v4[name] = a }
                    else if !a.hasPrefix("fe80"), v6[name] == nil { v6[name] = a }
                    else if v6[name] == nil { v6[name] = a }
                }
                p = c.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }
        var out: [NetSample] = []
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if h.ifm_msglen == 0 { break }
                if h.ifm_type == 0x12 {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var nb = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &nb) != nil {
                        let bsd = String(cString: nb)
                        if let (title, wifi) = hw[bsd], up.contains(bsd), v4[bsd] != nil || v6[bsd] != nil {
                            let rx = m.ifm_data.ifi_ibytes, tx = m.ifm_data.ifi_obytes
                            var s = NetSample(bsd: bsd, title: wifi ? "Wi-Fi" : title, subtitle: wifi ? bsd : bsd, isWiFi: wifi)
                            if let pv = prevNets[bsd] {
                                s.downBps = rx >= pv.0 ? Double(rx - pv.0) / dt : 0
                                s.upBps = tx >= pv.1 ? Double(tx - pv.1) / dt : 0
                            }
                            prevNets[bsd] = (rx, tx)
                            s.linkSpeed = Double(m.ifm_data.ifi_baudrate)
                            s.ipv4 = v4[bsd] ?? ""
                            s.ipv6 = v6[bsd] ?? ""
                            if wifi, let w = CWWiFiClient.shared().interface(withName: bsd) {
                                s.ssid = w.ssid() ?? ""
                                s.rssi = w.rssiValue()
                                s.linkSpeed = w.transmitRate() * 1e6
                            }
                            out.append(s)
                        }
                    }
                }
                off += Int(h.ifm_msglen)
            }
        }
        return out.sorted { ($0.isWiFi ? 0 : 1, $0.bsd) < ($1.isWiFi ? 0 : 1, $1.bsd) }
    }

    // MARK: GPU

    private func sampleGPU(_ snap: inout Snapshot, dt: Double) -> [Int32: Double] {
        var g = GPUSample()
        g.name = gpuName
        var iter: io_iterator_t = 0
        var perPid: [Int32: UInt64] = [:]
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS {
            while case let s = IOIteratorNext(iter), s != 0 {
                if let p = props(s) {
                    if let st = p["PerformanceStatistics"] as? [String: Any] {
                        g.utilization = max(g.utilization, (st["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
                        g.memoryInUse = (st["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                        g.memoryAllocated = (st["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0
                    }
                    if let c = p["gpu-core-count"] as? NSNumber { g.cores = c.intValue }
                }
                var ci: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(s, kIOServicePlane, &ci) == KERN_SUCCESS {
                    while case let c = IOIteratorNext(ci), c != 0 {
                        if let cp = props(c), let creator = cp["IOUserClientCreator"] as? String,
                           let usage = cp["AppUsage"] as? [[String: Any]], creator.hasPrefix("pid ") {
                            let digits = creator.dropFirst(4).prefix { $0.isNumber }
                            if let pid = Int32(digits) {
                                let t = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                                perPid[pid, default: 0] += t
                            }
                        }
                        IOObjectRelease(c)
                    }
                    IOObjectRelease(ci)
                }
                IOObjectRelease(s)
            }
            IOObjectRelease(iter)
        }
        snap.gpu = g
        var rates: [Int32: Double] = [:]
        for (pid, t) in perPid {
            if let pv = prevGPU[pid], t >= pv { rates[pid] = min(100, Double(t - pv) / (dt * 1e9) * 100) }
        }
        prevGPU = perPid
        return rates
    }
}
