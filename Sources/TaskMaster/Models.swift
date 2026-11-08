import Foundation

struct ProcSample: Sendable, Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    var name: String
    var path: String
    var cpu: Double = 0          // % of the whole machine
    var cpuTime: Double = 0      // seconds
    var memory: UInt64 = 0
    var diskRate: Double = 0     // bytes/s
    var netRate: Double = 0      // bytes/s
    var gpu: Double = 0          // %
    var power: Double = 0        // watts
    var threads: Int = 0
    var suspended = false
    var translated = false
    var startTime: Date = .distantPast
    var accessible = true
    // per-tick deltas feeding App history
    var cpuDelta: Double = 0
    var diskDelta: UInt64 = 0
    var netDelta: UInt64 = 0
}

struct MemSample: Sendable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int = 1
    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
}

struct DiskSample: Sendable, Identifiable {
    var id: UInt64
    var index: Int
    var name: String
    var kind: String
    var capacity: UInt64
    var readBps: Double = 0
    var writeBps: Double = 0
    var active: Double = 0       // %
    var responseMs: Double = 0
}

struct NetSample: Sendable, Identifiable {
    var id: String { bsd }
    var bsd: String
    var title: String
    var subtitle: String
    var isWiFi: Bool
    var downBps: Double = 0      // bytes/s
    var upBps: Double = 0
    var linkSpeed: Double = 0    // bits/s
    var ipv4 = ""
    var ipv6 = ""
    var ssid = ""
    var rssi = 0
}

struct GPUSample: Sendable {
    var name = ""
    var cores = 0
    var utilization: Double = 0
    var memoryInUse: UInt64 = 0
    var memoryAllocated: UInt64 = 0
}

struct Snapshot: Sendable {
    var time = Date()
    var interval: Double = 1
    var procs: [ProcSample] = []
    var cpu: Double = 0
    var cores: [Double] = []
    var mem = MemSample()
    var disks: [DiskSample] = []
    var nets: [NetSample] = []
    var gpu = GPUSample()
    var threads = 0
    var handles = 0
    var uptime: TimeInterval = 0
    var diskTotalBps: Double { disks.reduce(0) { $0 + $1.readBps + $1.writeBps } }
    var netTotalBps: Double { nets.reduce(0) { $0 + $1.downBps + $1.upBps } }
}

struct StaticInfo: Sendable {
    var chip = Sys.string("machdep.cpu.brand_string") ?? "Apple silicon"
    var model = Sys.string("hw.model") ?? ""
    var logical = ProcessInfo.processInfo.processorCount
    var performanceCores = Sys.int("hw.perflevel0.physicalcpu") ?? 0
    var efficiencyCores = Sys.int("hw.perflevel1.physicalcpu") ?? 0
    var l1d = Sys.int("hw.perflevel0.l1dcachesize") ?? 0
    var l1i = Sys.int("hw.perflevel0.l1icachesize") ?? 0
    var l2 = Sys.int("hw.perflevel0.l2cachesize") ?? 0
    var memory = UInt64(ProcessInfo.processInfo.physicalMemory)
    var virtualization = (Sys.int("kern.hv_support") ?? 0) == 1
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
}
