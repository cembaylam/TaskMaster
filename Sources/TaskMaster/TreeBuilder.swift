import Foundation

struct AppRef: Sendable {
    var pid: Int32
    var bundlePath: String
    var name: String
    var regular: Bool
}

enum TreeBuilder {
    struct Result { var apps: [ProcNode] = []; var background: [ProcNode] = []; var system: [ProcNode] = [] }

    static func bundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.upperBound].dropLast())
    }

    static func bundleName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func node(_ p: ProcSample, name: String? = nil, efficient: Set<Int32>) -> ProcNode {
        var n = ProcNode(id: "p:\(p.pid)", kind: .process, name: name ?? p.name, iconPath: p.path, pids: [p.pid], uid: p.uid, path: p.path)
        n.cpu = p.cpu; n.memory = p.memory; n.disk = p.diskRate; n.net = p.netRate; n.gpu = p.gpu; n.power = p.power
        n.suspended = p.suspended
        n.threads = p.threads; n.cpuTime = p.cpuTime; n.translated = p.translated
        n.efficient = efficient.contains(p.pid)
        n.cpuDelta = p.cpuDelta; n.diskDelta = p.diskDelta; n.netDelta = p.netDelta
        n.historyKey = p.path
        return n
    }

    static func build(_ procs: [ProcSample], apps: [AppRef], efficient: Set<Int32>) -> Result {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let regular = Dictionary(apps.filter(\.regular).map { ($0.bundlePath, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [Int32: String?] = [:]

        func appKey(_ pid: Int32, depth: Int = 0) -> String? {
            if let m = memo[pid] { return m }
            guard let p = byPid[pid], depth < 12 else { return nil }
            var result: String?
            if let b = bundle(p.path), regular[b] != nil { result = b }
            else if p.ppid > 1, byPid[p.ppid] != nil { result = appKey(p.ppid, depth: depth + 1) }
            memo[pid] = .some(result)
            return result
        }

        var groups: [String: [ProcSample]] = [:]
        for p in procs {
            let key = appKey(p.pid) ?? bundle(p.path) ?? "pid:\(p.pid)"
            groups[key, default: []].append(p)
        }

        var res = Result()
        for (key, members) in groups {
            let app = regular[key]
            let isBundle = key.hasSuffix(".app")
            let sorted = members.sorted { $0.pid < $1.pid }
            var node: ProcNode
            if sorted.count == 1 {
                let name = app?.name ?? (isBundle ? bundleName(key) : nil)
                node = Self.node(sorted[0], name: name, efficient: efficient)
                node.isApp = app != nil
                if isBundle { node.iconPath = key }
            } else {
                node = ProcNode(id: "g:\(key)", kind: .group, name: app?.name ?? (isBundle ? bundleName(key) : sorted[0].name),
                                iconPath: isBundle ? key : sorted[0].path, pids: sorted.map(\.pid), uid: sorted[0].uid, path: isBundle ? key : sorted[0].path)
                node.isApp = app != nil
                node.children = sorted.map { Self.node($0, efficient: efficient) }
                node.count = sorted.count
                for c in node.children {
                    node.cpu += c.cpu; node.memory += c.memory; node.disk += c.disk; node.net += c.net
                    node.gpu += c.gpu; node.power += c.power
                    node.cpuDelta += c.cpuDelta; node.diskDelta += c.diskDelta; node.netDelta += c.netDelta
                }
                node.gpu = min(100, node.gpu)
                node.threads = node.children.reduce(0) { $0 + $1.threads }
                node.cpuTime = node.children.reduce(0) { $0 + $1.cpuTime }
                node.suspended = node.children.allSatisfy(\.suspended)
                node.efficient = node.children.allSatisfy(\.efficient)
            }
            node.historyKey = isBundle ? key : sorted[0].path.isEmpty ? sorted[0].name : sorted[0].path
            if node.isApp { res.apps.append(node) }
            else if members.allSatisfy({ $0.uid < 500 }) { res.system.append(node) }
            else { res.background.append(node) }
        }
        return res
    }

    static func sections(_ r: Result) -> [ProcNode] {
        func section(_ id: String, _ name: String, _ nodes: [ProcNode]) -> ProcNode {
            var s = ProcNode(id: id, kind: .section, name: name)
            s.children = nodes
            s.count = nodes.count
            return s
        }
        var out: [ProcNode] = []
        if !r.apps.isEmpty { out.append(section("s:apps", "Apps", r.apps)) }
        if !r.background.isEmpty { out.append(section("s:bg", "Background processes", r.background)) }
        if !r.system.isEmpty { out.append(section("s:sys", "macOS processes", r.system)) }
        return out
    }

    static func users(_ procs: [ProcSample], apps: [AppRef], efficient: Set<Int32>, fullName: Bool, activeUID: UInt32) -> [ProcNode] {
        var out: [ProcNode] = []
        // real accounts, root, and one bucket for the many _service accounts
        for (uid, list) in Dictionary(grouping: procs, by: { $0.uid >= 500 || $0.uid == 0 ? $0.uid : 1 }) {
            let r = build(list, apps: apps, efficient: efficient)
            let kids = r.apps + r.background + r.system
            let title = uid == 1 ? "System accounts" : (fullName ? Users.fullName(uid) : Users.name(uid))
            var n = ProcNode(id: "u:\(uid)", kind: .group, name: title, uid: uid)
            n.children = kids
            n.count = kids.count
            n.pids = list.map(\.pid)
            n.isApp = uid == activeUID
            for c in kids { n.cpu += c.cpu; n.memory += c.memory; n.disk += c.disk; n.net += c.net }
            out.append(n)
        }
        func rank(_ n: ProcNode) -> Int { n.uid == activeUID ? 0 : (n.uid >= 500 ? 1 : (n.uid == 0 ? 2 : 3)) }
        return out.sorted { (rank($0), $0.uid) < (rank($1), $1.uid) }
    }

    static func sort(_ nodes: [ProcNode], by spec: SortSpec) -> [ProcNode] {
        func value(_ n: ProcNode) -> Double {
            switch spec.key {
            case .cpu: n.cpu
            case .memory: Double(n.memory)
            case .disk: n.disk
            case .network: n.net
            case .gpu: n.gpu
            case .power: n.power
            case .status: n.suspended ? 2 : (n.efficient ? 1 : 0)
            case .pid: Double(n.pid ?? 0)
            case .cpuTime: n.cpuTime
            case .threads: Double(n.threads)
            default: 0
            }
        }
        var out = nodes.map { n -> ProcNode in
            var m = n
            if !m.children.isEmpty { m.children = sort(m.children, by: spec) }
            return m
        }
        out.sort { a, b in
            if a.kind == .section || b.kind == .section { return false }
            if [.name, .user, .arch, .description].contains(spec.key) {
                func str(_ n: ProcNode) -> String {
                    switch spec.key {
                    case .user: Users.name(n.uid)
                    case .arch: n.translated ? "x86_64" : "arm64"
                    case .description: n.path
                    default: n.name
                    }
                }
                let c = str(a).localizedCaseInsensitiveCompare(str(b))
                return spec.ascending ? c == .orderedAscending : c == .orderedDescending
            }
            let (x, y) = (value(a), value(b))
            if x == y { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            return spec.ascending ? x < y : x > y
        }
        return out
    }
}
