import SwiftUI
import AppKit
import Observation

struct HistoryEntry: Codable, Hashable {
    var name: String
    var path: String
    var isApp: Bool
    var cpu: Double = 0
    var net: UInt64 = 0
    var disk: UInt64 = 0
}

struct HistoryStore: Codable {
    var since = Date()
    var entries: [String: HistoryEntry] = [:]
}

struct EndRequest: Identifiable {
    let id = UUID()
    var name: String
    var pids: [Int32]
    var tree: Bool
    var system: Bool
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor @Observable
final class Monitor {
    static let length = 60

    let settings: AppSettings
    let info = StaticInfo()
    private let sampler = Sampler()
    private var loop: Task<Void, Never>?

    var snapshot = Snapshot()
    var tick = 0
    var apps: [AppRef] = []
    var efficient: Set<Int32> = []

    var cpuHistory = [Double](repeating: 0, count: length)
    var coreHistory: [[Double]] = []
    var memHistory = [Double](repeating: 0, count: length)
    var gpuHistory = [Double](repeating: 0, count: length)
    var gpuMemHistory = [Double](repeating: 0, count: length)
    var diskActive: [UInt64: [Double]] = [:]
    var diskRead: [UInt64: [Double]] = [:]
    var diskWrite: [UInt64: [Double]] = [:]
    var netUp: [String: [Double]] = [:]
    var netDown: [String: [Double]] = [:]

    var sections: [ProcNode] = []
    var userNodes: [ProcNode] = []

    var history = HistoryStore()
    private var lastSave = Date()

    var services: [ServiceItem] = []
    var startupItems: [StartupItem] = []
    var startupLoaded = false

    var pendingEnd: EndRequest?
    var alert: AlertMessage?

    init(settings: AppSettings) {
        self.settings = settings
        loadHistory()
    }

    // MARK: loop

    func start() {
        guard loop == nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let sec = self.settings.updateSpeed.seconds {
                    let s = await self.sampler.sample()
                    self.apply(s)
                    try? await Task.sleep(for: .seconds(sec))
                } else {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    func refreshNow() {
        Task { let s = await sampler.sample(); apply(s) }
    }

    func shutdown() {
        saveHistory()
        Task { await sampler.stop() }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.removeFirst()
        a.append(v)
    }

    private func series(_ dict: inout [String: [Double]], _ key: String, _ v: Double) {
        var a = dict[key] ?? [Double](repeating: 0, count: Self.length)
        push(&a, v)
        dict[key] = a
    }

    private func series(_ dict: inout [UInt64: [Double]], _ key: UInt64, _ v: Double) {
        var a = dict[key] ?? [Double](repeating: 0, count: Self.length)
        push(&a, v)
        dict[key] = a
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        tick &+= 1
        push(&cpuHistory, s.cpu)
        if coreHistory.count != s.cores.count { coreHistory = s.cores.map { _ in [Double](repeating: 0, count: Self.length) } }
        for (i, v) in s.cores.enumerated() { push(&coreHistory[i], v) }
        push(&memHistory, s.mem.total > 0 ? Double(s.mem.used) / Double(s.mem.total) * 100 : 0)
        push(&gpuHistory, s.gpu.utilization)
        push(&gpuMemHistory, s.mem.total > 0 ? Double(s.gpu.memoryInUse) / Double(s.mem.total) * 100 : 0)
        for d in s.disks {
            series(&diskActive, d.id, d.active)
            series(&diskRead, d.id, d.readBps)
            series(&diskWrite, d.id, d.writeBps)
        }
        for n in s.nets {
            series(&netUp, n.bsd, n.upBps)
            series(&netDown, n.bsd, n.downBps)
        }

        apps = NSWorkspace.shared.runningApplications.compactMap { a in
            guard let url = a.bundleURL else { return nil }
            return AppRef(pid: a.processIdentifier, bundlePath: url.path, name: a.localizedName ?? url.deletingPathExtension().lastPathComponent,
                          regular: a.activationPolicy == .regular)
        }
        efficient.formIntersection(Set(s.procs.map(\.pid)))

        let r = TreeBuilder.build(s.procs, apps: apps, efficient: efficient)
        sections = TreeBuilder.sections(r)
        accumulate(r)
        userNodes = TreeBuilder.users(s.procs, apps: apps, efficient: efficient, fullName: settings.showFullAccountName, activeUID: getuid())
        if Date().timeIntervalSince(lastSave) > 30 { saveHistory() }
    }

    // MARK: app history

    private var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TaskMaster")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func loadHistory() {
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode(HistoryStore.self, from: d) { history = h }
    }

    func saveHistory() {
        lastSave = Date()
        if let d = try? JSONEncoder().encode(history) { try? d.write(to: historyURL, options: .atomic) }
    }

    func resetHistory() {
        history = HistoryStore()
        saveHistory()
    }

    private func accumulate(_ r: TreeBuilder.Result) {
        for n in r.apps + r.background where !n.historyKey.isEmpty {
            var e = history.entries[n.historyKey] ?? HistoryEntry(name: n.name, path: n.iconPath, isApp: n.isApp)
            e.cpu += n.cpuDelta
            e.net += n.netDelta
            e.disk += n.diskDelta
            e.name = n.name
            e.isApp = n.isApp
            history.entries[n.historyKey] = e
        }
    }

    // MARK: process actions

    func process(_ pid: Int32) -> ProcSample? { snapshot.procs.first { $0.pid == pid } }

    func descendants(of pids: [Int32]) -> [Int32] {
        var kids: [Int32: [Int32]] = [:]
        for p in snapshot.procs { kids[p.ppid, default: []].append(p.pid) }
        var out: [Int32] = []
        var stack = pids
        while let x = stack.popLast() {
            for k in kids[x] ?? [] where !out.contains(k) && !pids.contains(k) { out.append(k); stack.append(k) }
        }
        return out
    }

    /// Entry point for every "End task" / "End process" command.
    func requestEnd(name: String, pids: [Int32], tree: Bool = false) {
        let isSystem = pids.contains { pid in (process(pid)?.uid ?? 0) < 500 }
        let req = EndRequest(name: name, pids: pids, tree: tree, system: isSystem)
        if isSystem && settings.confirmSystemKill { pendingEnd = req } else { perform(req) }
    }

    func perform(_ req: EndRequest) {
        var targets = req.pids
        if req.tree { targets += descendants(of: req.pids) }
        var failed = 0
        for pid in targets {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, pid == req.pids.first, !req.tree {
                app.terminate()
                continue
            }
            if kill(pid, SIGTERM) != 0 { failed += 1 }
        }
        // escalate to SIGKILL for anything that ignored SIGTERM
        Task { [targets] in
            try? await Task.sleep(for: .seconds(3))
            for pid in targets where kill(pid, 0) == 0 {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { continue }
                kill(pid, SIGKILL)
            }
        }
        if failed > 0 {
            alert = AlertMessage(title: "Unable to end \(req.name)", message: "Access is denied. Processes owned by other users or by macOS require administrator rights.")
        }
    }

    func setPriority(_ pids: [Int32], nice: Int32) {
        var failed = false
        for pid in pids where setpriority(PRIO_PROCESS, UInt32(pid), nice) != 0 { failed = true }
        if failed {
            alert = AlertMessage(title: "Unable to change priority", message: "Raising priority above Normal or changing processes owned by another user requires administrator rights.")
        }
    }

    func priority(of pid: Int32) -> Int32 { Int32(getpriority(PRIO_PROCESS, UInt32(pid))) }

    func setEfficiency(_ pids: [Int32], on: Bool) {
        Task {
            for pid in pids {
                let (st, _) = await Launchd.run("/usr/sbin/taskpolicy", [on ? "-b" : "-B", "-p", "\(pid)"])
                if st == 0 { _ = setpriority(PRIO_PROCESS, UInt32(pid), on ? 19 : 0) }
                if st == 0 { if on { efficient.insert(pid) } else { efficient.remove(pid) } }
                else { alert = AlertMessage(title: "Unable to change efficiency mode", message: "macOS did not allow changing the scheduling policy of this process.") }
            }
        }
    }

    func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func searchOnline(_ name: String) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(name) process macOS")]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    func sampleProcess(_ pid: Int32, name: String) {
        Task {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)_\(pid)_sample.txt").path
            let (st, text) = await Launchd.run("/usr/bin/sample", ["\(pid)", "3", "-file", out])
            if st == 0 { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }
            else { alert = AlertMessage(title: "Unable to sample \(name)", message: text) }
        }
    }

    func runNewTask(_ command: String, admin: Bool) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        if admin {
            Task { if let e = await Launchd.runPrivileged(c) { alert = AlertMessage(title: "Unable to run \(c)", message: e) } }
            return
        }
        let expanded = (c as NSString).expandingTildeInPath
        if let u = URL(string: c), u.scheme != nil, u.host != nil { NSWorkspace.shared.open(u); return }
        if FileManager.default.fileExists(atPath: expanded), expanded.hasSuffix(".app") || !FileManager.default.isExecutableFile(atPath: expanded) {
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded)); return
        }
        Task {
            let (st, out) = await Launchd.run("/bin/zsh", ["-lc", "nohup \(c) >/dev/null 2>&1 &"])
            if st != 0 { alert = AlertMessage(title: "TaskMaster cannot find '\(c)'", message: out) }
        }
    }

    // MARK: lists

    func refreshServices() {
        Task { services = await Launchd.services() }
    }

    func refreshStartup() {
        Task {
            var items = await Startup.agents()
            startupItems = items
            startupLoaded = true
            var logins = await Startup.loginItems()
            let removed = UserDefaults.standard.dictionary(forKey: "removedLoginItems") as? [String: String] ?? [:]
            for (name, path) in removed where !logins.contains(where: { $0.path == path }) {
                logins.append(StartupItem(id: "login:" + path, name: name, publisher: Startup.publisher(for: path), kind: .loginItem, path: path,
                                          program: path, label: name, enabled: false, domain: "login"))
            }
            items += logins
            var seen = Set<String>()
            items = items.filter { seen.insert($0.id).inserted }
            startupItems = items
        }
    }

    func setStartup(_ item: StartupItem, enabled: Bool) {
        Task {
            if let err = await Startup.setEnabled(item, enabled) {
                alert = AlertMessage(title: "Unable to \(enabled ? "enable" : "disable") \(item.name)", message: err)
                return
            }
            if item.kind == .loginItem {
                var removed = UserDefaults.standard.dictionary(forKey: "removedLoginItems") as? [String: String] ?? [:]
                if enabled { removed[item.name] = nil } else { removed[item.name] = item.path }
                UserDefaults.standard.set(removed, forKey: "removedLoginItems")
            }
            refreshStartup()
        }
    }

    func impact(for item: StartupItem) -> String {
        guard let p = snapshot.procs.first(where: { !item.program.isEmpty && $0.path == item.program }) else { return "Not measured" }
        let rate = p.cpuTime / max(snapshot.uptime, 1) * 100
        return p.cpuTime < 3 && rate < 0.05 ? "Low" : (p.cpuTime < 30 ? "Medium" : "High")
    }
}
