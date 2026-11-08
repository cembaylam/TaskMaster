import SwiftUI
import Observation

enum PerfItem: Hashable, Identifiable {
    case cpu, memory, disk(UInt64), network(String), gpu
    var id: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "mem"
        case .disk(let i): "disk\(i)"
        case .network(let b): "net\(b)"
        case .gpu: "gpu"
        }
    }
}

struct PropertiesTarget: Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var pid: Int32?
}

@MainActor @Observable
final class UIState {
    var page: Page
    var search = ""
    var expanded: Set<String> = ["s:apps", "s:bg", "s:sys"]
    var processSelection: String?
    var userSelection: String?
    var detailsSelection: Int32?
    var serviceSelection: String?
    var startupSelection: String?
    var historySelection: String?
    var processSort = SortSpec(key: .name)
    var userSort = SortSpec(key: .name)
    var detailsSort = SortSpec(key: .name)
    var perf: PerfItem = .cpu
    var graphOnly = false
    var cpuLogical = false
    var showRunSheet = false
    var searchFocusTick = 0
    var selectFirstTick = 0
    var properties: PropertiesTarget?

    init(start: Page) { page = start }

    func goToDetails(pid: Int32) {
        detailsSelection = pid
        page = .details
    }
}

struct ColumnDef: Identifiable {
    var id: String
    var title: String
    var width: CGFloat
    var key: SortKey
    var resource = false
    var alignRight = false
}

enum Columns {
    static let all: [String: ColumnDef] = [
        "name": .init(id: "name", title: "Name", width: 0, key: .name),
        "status": .init(id: "status", title: "Status", width: 104, key: .status),
        "pid": .init(id: "pid", title: "PID", width: 70, key: .pid, alignRight: true),
        "user": .init(id: "user", title: "User name", width: 104, key: .user),
        "cpu": .init(id: "cpu", title: "CPU", width: 84, key: .cpu, resource: true, alignRight: true),
        "cpuTime": .init(id: "cpuTime", title: "CPU time", width: 90, key: .cpuTime, alignRight: true),
        "memory": .init(id: "memory", title: "Memory", width: 100, key: .memory, resource: true, alignRight: true),
        "disk": .init(id: "disk", title: "Disk", width: 100, key: .disk, resource: true, alignRight: true),
        "network": .init(id: "network", title: "Network", width: 100, key: .network, resource: true, alignRight: true),
        "gpu": .init(id: "gpu", title: "GPU", width: 84, key: .gpu, resource: true, alignRight: true),
        "power": .init(id: "power", title: "Power usage", width: 104, key: .power, resource: true, alignRight: true),
        "threads": .init(id: "threads", title: "Threads", width: 76, key: .threads, alignRight: true),
        "arch": .init(id: "arch", title: "Architecture", width: 100, key: .arch),
        "description": .init(id: "description", title: "Description", width: 0, key: .description),
    ]
    static let processes = ["name", "status", "cpu", "memory", "disk", "network", "gpu", "power"]
    static let users = ["name", "status", "cpu", "memory", "disk", "network", "gpu"]
    static let detailsOrder = ["name", "pid", "status", "user", "cpu", "cpuTime", "memory", "threads", "arch", "description", "disk", "network", "gpu", "power"]
}
