import Foundation

struct ProcNode: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case section, group, process }
    var id: String
    var kind: Kind
    var name: String
    var iconPath: String = ""
    var pids: [Int32] = []
    var uid: UInt32 = 0
    var path: String = ""
    var isApp = false
    var cpu = 0.0, disk = 0.0, net = 0.0, gpu = 0.0, power = 0.0
    var memory: UInt64 = 0
    var suspended = false
    var efficient = false
    var count = 0
    var threads = 0
    var cpuTime = 0.0
    var translated = false
    var children: [ProcNode] = []
    // deltas for history
    var cpuDelta = 0.0
    var diskDelta: UInt64 = 0
    var netDelta: UInt64 = 0
    var historyKey = ""

    var pid: Int32? { pids.count == 1 ? pids[0] : nil }
}

enum SortKey: String, Sendable { case name, cpu, memory, disk, network, gpu, power, status, pid, user, cpuTime, arch, description, threads }

struct SortSpec: Equatable, Sendable {
    var key: SortKey = .name
    var ascending = true
}
