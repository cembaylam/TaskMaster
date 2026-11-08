import SwiftUI
import AppKit

extension Monitor {
    func endNode(_ n: ProcNode, tree: Bool = false) {
        guard n.kind != .section, !n.id.hasPrefix("u:") else { return }
        if n.isApp, let a = apps.first(where: { $0.regular && ($0.bundlePath == n.path || n.pids.contains($0.pid)) }) {
            requestEnd(name: n.name, pids: [a.pid], tree: tree)
        } else {
            requestEnd(name: n.name, pids: n.pids, tree: tree)
        }
    }

    func appPID(for n: ProcNode) -> Int32? {
        apps.first(where: { $0.regular && ($0.bundlePath == n.path || n.pids.contains($0.pid)) })?.pid
    }
}

func filterNodes(_ nodes: [ProcNode], _ q: String) -> [ProcNode] {
    let q = q.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return nodes }
    return nodes.compactMap { n in
        let own = n.kind != .section && (n.name.localizedCaseInsensitiveContains(q) || n.path.localizedCaseInsensitiveContains(q) || n.pids.contains { String($0) == q })
        if own { return n }
        guard !n.children.isEmpty else { return nil }
        var m = n
        m.children = filterNodes(n.children, q)
        m.count = m.children.count
        return m.children.isEmpty ? nil : m
    }
}

func findNode(_ nodes: [ProcNode], _ id: String?) -> ProcNode? {
    guard let id else { return nil }
    for n in nodes {
        if n.id == id { return n }
        if let c = findNode(n.children, id) { return c }
    }
    return nil
}

// MARK: - Context menu

struct ProcessMenu: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings
    var node: ProcNode
    var detailed = false

    var body: some View {
        if node.kind != .section && !node.id.hasPrefix("u:") {
            if !node.children.isEmpty {
                if ui.expanded.contains(node.id) { Button("Collapse") { ui.expanded.remove(node.id) } }
                else { Button("Expand") { ui.expanded.insert(node.id) } }
                Divider()
            }
            if let pid = monitor.appPID(for: node) { Button("Switch to") { monitor.activate(pid: pid) } }
            Button(detailed ? "End process" : "End task") { monitor.endNode(node) }
            if detailed { Button("End process tree") { monitor.endNode(node, tree: true) } }
            if detailed, !node.pids.isEmpty {
                Menu("Set priority") {
                    ForEach([("High", -10), ("Above normal", -5), ("Normal", 0), ("Below normal", 5), ("Low", 10)], id: \.0) { name, nice in
                        Button(name) { monitor.setPriority(node.pids, nice: Int32(nice)) }
                    }
                }
            }
            Button(node.efficient ? "Turn off efficiency mode" : "Efficiency mode") { monitor.setEfficiency(node.pids, on: !node.efficient) }
            if !detailed {
                Menu("Resource values") {
                    Menu("Memory") {
                        Toggle("Values", isOn: Binding(get: { !settings.memoryAsPercent }, set: { _ in settings.memoryAsPercent = false }))
                        Toggle("Percents", isOn: Binding(get: { settings.memoryAsPercent }, set: { _ in settings.memoryAsPercent = true }))
                    }
                }
            }
            Divider()
            if detailed, let pid = node.pid {
                Button("Sample process") { monitor.sampleProcess(pid, name: node.name) }
                Button("Go to service(s)") {
                    if let s = monitor.services.first(where: { $0.pid == pid }) { ui.serviceSelection = s.id }
                    ui.page = .services
                }
            }
            if !detailed, let pid = node.pids.first { Button("Go to details") { ui.goToDetails(pid: node.pid ?? pid) } }
            Button("Open file location") { monitor.reveal(path: node.path) }.disabled(node.path.isEmpty)
            Button("Search online") { monitor.searchOnline(node.name) }
            Button("Properties") { ui.properties = PropertiesTarget(name: node.name, path: node.path, pid: node.pid) }
        }
    }
}

struct ViewMenu: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings
    var tree = true

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Button("Refresh now") { monitor.refreshNow() }
            Menu("Update speed") {
                Picker("Update speed", selection: $settings.updateSpeed) { ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
            }
            if tree {
                Divider()
                Button("Expand all") {
                    func ids(_ n: [ProcNode]) -> [String] { n.flatMap { [$0.id] + ids($0.children) } }
                    ui.expanded.formUnion(ids(monitor.sections) + ids(monitor.userNodes))
                }
                Button("Collapse all") { ui.expanded = ["s:apps", "s:bg", "s:sys"] }
            }
            Divider()
            Toggle("Show memory as percent", isOn: $settings.memoryAsPercent)
            Toggle("Always on top", isOn: $settings.alwaysOnTop)
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 36)
        .help("View options")
    }
}

// MARK: - Processes

struct ProcessesPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let nodes = TreeBuilder.sort(filterNodes(monitor.sections, ui.search), by: ui.processSort)
        let selected = findNode(monitor.sections, ui.processSelection)
        let actionable = selected.map { $0.kind != .section } ?? false
        VStack(spacing: 0) {
            PageHeader(title: "Processes") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { ui.showRunSheet = true }
                CommandButton(title: "End task", symbol: "xmark.circle", disabled: !actionable) { if let s = selected { monitor.endNode(s) } }
                CommandButton(title: "Efficiency mode", symbol: "leaf", disabled: !actionable) {
                    if let s = selected { monitor.setEfficiency(s.pids, on: !s.efficient) }
                }
                ViewMenu()
            }
            ProcessTable(columns: Columns.processes, nodes: nodes, rowHeight: 38, selection: $ui.processSelection, expanded: $ui.expanded,
                         sort: $ui.processSort, onOpen: { n in
                             if n.kind == .section { toggle(n.id) } else if let p = monitor.appPID(for: n) { monitor.activate(pid: p) } else { toggle(n.id) }
                         }) { n in ProcessMenu(node: n) }
                .forceExpandIfSearching(!ui.search.isEmpty)
        }
    }

    private func toggle(_ id: String) {
        if ui.expanded.contains(id) { ui.expanded.remove(id) } else { ui.expanded.insert(id) }
    }
}

extension ProcessTable {
    func forceExpandIfSearching(_ on: Bool) -> ProcessTable {
        var c = self
        c.forceExpand = on
        return c
    }
}

// MARK: - Users

struct UsersPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let nodes = TreeBuilder.sort(filterNodes(monitor.userNodes, ui.search), by: ui.userSort)
        let selected = findNode(monitor.userNodes, ui.userSelection)
        VStack(spacing: 0) {
            PageHeader(title: "Users") {
                CommandButton(title: "End task", symbol: "xmark.circle", disabled: selected == nil || selected!.id.hasPrefix("u:")) {
                    if let s = selected { monitor.endNode(s) }
                }
                ViewMenu()
            }
            ProcessTable(columns: Columns.users, nodes: nodes, rowHeight: 40, selection: $ui.userSelection, expanded: $ui.expanded,
                         sort: $ui.userSort) { n in ProcessMenu(node: n) }
                .forceExpandIfSearching(!ui.search.isEmpty)
        }
    }
}

// MARK: - Details

struct DetailsPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var ui = ui
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        let all = monitor.snapshot.procs.map { TreeBuilder.node($0, efficient: monitor.efficient) }
        let flat = q.isEmpty ? all : filterNodes(all, q)
        let sorted = TreeBuilder.sort(flat, by: ui.detailsSort)
        let selection = Binding<String?>(get: { ui.detailsSelection.map { "p:\($0)" } },
                                         set: { ui.detailsSelection = $0.flatMap { Int32($0.dropFirst(2)) } })
        let selected = ui.detailsSelection.flatMap { pid in flat.first { $0.pid == pid } }
        let cols = Columns.detailsOrder.filter { settings.detailsColumns.contains($0) }
        VStack(spacing: 0) {
            PageHeader(title: "Details") {
                CommandButton(title: "End task", symbol: "xmark.circle", disabled: selected == nil) { if let s = selected { monitor.endNode(s) } }
                CommandButton(title: "Efficiency mode", symbol: "leaf", disabled: selected == nil) { if let s = selected { monitor.setEfficiency(s.pids, on: !s.efficient) } }
                ViewMenu(tree: false)
            }
            ProcessTable(columns: cols, nodes: sorted, showTotals: false, rowHeight: 28, selection: selection,
                         expanded: .constant([]), sort: $ui.detailsSort,
                         onOpen: { n in ui.properties = PropertiesTarget(name: n.name, path: n.path, pid: n.pid) },
                         onHeaderMenu: { AnyView(ColumnMenu()) }) { n in ProcessMenu(node: n, detailed: true) }
        }
    }
}

struct ColumnMenu: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        Text("Select columns")
        ForEach(Columns.detailsOrder.filter { $0 != "name" }, id: \.self) { id in
            Toggle(Columns.all[id]?.title ?? id, isOn: Binding(
                get: { settings.detailsColumns.contains(id) },
                set: { on in
                    if on { settings.detailsColumns.append(id) } else { settings.detailsColumns.removeAll { $0 == id } }
                }))
        }
    }
}
