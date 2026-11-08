import SwiftUI
import AppKit

private struct Row: Identifiable {
    var node: ProcNode
    var depth: Int
    var id: String { node.id }
}

struct ProcessTable<Menu: View>: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var columns: [String]
    var nodes: [ProcNode]
    var showTotals = true
    var forceExpand = false
    var rowHeight: CGFloat = 38
    var selection: Binding<String?>
    var expanded: Binding<Set<String>>
    var sort: Binding<SortSpec>
    var onOpen: (ProcNode) -> Void = { _ in }
    var onHeaderMenu: (() -> AnyView)?
    @ViewBuilder var menu: (ProcNode) -> Menu
    @State private var keys = KeyMonitor()

    private func flatten(_ nodes: [ProcNode], depth: Int, into out: inout [Row]) {
        for n in nodes {
            out.append(Row(node: n, depth: depth))
            if !n.children.isEmpty && (forceExpand || expanded.wrappedValue.contains(n.id)) { flatten(n.children, depth: depth + 1, into: &out) }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        flatten(nodes, depth: 0, into: &out)
        return out
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                    ForEach(rows) { row in
                        RowView(row: row.node, depth: row.depth, columns: columns, height: rowHeight,
                                selected: selection.wrappedValue == row.id,
                                expanded: forceExpand || expanded.wrappedValue.contains(row.id),
                                percent: settings.memoryAsPercent, total: monitor.snapshot.mem.total,
                                fullName: settings.showFullAccountName,
                                toggle: { toggle(row.node) },
                                select: { NSApp.keyWindow?.makeFirstResponder(nil); selection.wrappedValue = row.id },
                                open: { onOpen(row.node) })
                            .contextMenu { menu(row.node) }
                    }
                    } header: {
                        VStack(spacing: 0) { header; Divider() }
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
            .onChange(of: selection.wrappedValue) { _, new in
                if let new { proxy.scrollTo(new) }
            }
            }
        }
        .onAppear {
            keys.onKey = { code in handleKey(code, rows) }
            keys.start()
        }
        .onDisappear { keys.stop() }
        .onChange(of: ui.selectFirstTick) { _, _ in
            if let first = rows.first(where: { $0.node.kind != .section }) { selection.wrappedValue = first.id }
        }
        .onChange(of: rows.count) { _, _ in keys.onKey = { code in handleKey(code, self.rows) } }
    }

    private func handleKey(_ code: UInt16, _ rows: [Row]) -> Bool {
        switch code {
        case 125: move(rows, 1)
        case 126: move(rows, -1)
        case 124: setExpanded(rows, true)
        case 123: setExpanded(rows, false)
        case 36, 76:
            guard let r = rows.first(where: { $0.id == selection.wrappedValue }) else { return false }
            onOpen(r.node)
        default: return false
        }
        return true
    }

    private func toggle(_ n: ProcNode) {
        guard !n.children.isEmpty else { return }
        if expanded.wrappedValue.contains(n.id) { expanded.wrappedValue.remove(n.id) } else { expanded.wrappedValue.insert(n.id) }
    }

    private func move(_ rows: [Row], _ d: Int) {
        guard !rows.isEmpty else { return }
        let idx = rows.firstIndex { $0.id == selection.wrappedValue } ?? (d > 0 ? -1 : rows.count)
        selection.wrappedValue = rows[min(max(idx + d, 0), rows.count - 1)].id
    }

    private func setExpanded(_ rows: [Row], _ on: Bool) {
        guard let r = rows.first(where: { $0.id == selection.wrappedValue }), !r.node.children.isEmpty else { return }
        if on { expanded.wrappedValue.insert(r.id) } else { expanded.wrappedValue.remove(r.id) }
    }

    // MARK: header

    private var totals: [String: String] {
        let s = monitor.snapshot
        let diskActive = s.disks.map(\.active).max() ?? 0
        let netLink = s.nets.map(\.linkSpeed).max() ?? 0
        let netPct = netLink > 0 ? min(100, s.netTotalBps * 8 / netLink * 100) : 0
        return ["cpu": Fmt.percent(s.cpu),
                "memory": Fmt.percent(s.mem.total > 0 ? Double(s.mem.used) / Double(s.mem.total) * 100 : 0),
                "disk": Fmt.percent(diskActive), "network": Fmt.percent(netPct), "gpu": Fmt.percent(s.gpu.utilization)]
    }

    private var header: some View {
        let t = totals
        return HStack(spacing: 0) {
            ForEach(columns, id: \.self) { id in
                if let c = Columns.all[id] {
                    let active = sort.wrappedValue.key == c.key
                    Button {
                        if active { sort.wrappedValue.ascending.toggle() }
                        else { sort.wrappedValue = SortSpec(key: c.key, ascending: c.key == .name || !c.resource) }
                    } label: {
                        VStack(alignment: c.alignRight ? .trailing : .leading, spacing: 1) {
                            if showTotals, c.resource, let v = t[id] { Text(v).font(.system(size: 14, weight: .medium)).monospacedDigit() }
                            else if showTotals && c.resource { Text(" ").font(.system(size: 14)) }
                            HStack(spacing: 3) {
                                if c.alignRight { Spacer(minLength: 0) }
                                Text(c.title).font(.system(size: 12)).foregroundStyle(showTotals && c.resource ? .secondary : .primary)
                                if active { Image(systemName: sort.wrappedValue.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: c.width == 0 ? .infinity : c.width, alignment: c.alignRight ? .trailing : .leading)
                        .frame(height: showTotals ? 46 : 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: c.width == 0 ? 150 : c.width, maxWidth: c.width == 0 ? .infinity : c.width)
                }
            }
        }
        .padding(.leading, 6)
        .contextMenu { onHeaderMenu?() }
    }
}

// MARK: - Row

private struct RowView: View {
    var row: ProcNode
    var depth: Int
    var columns: [String]
    var height: CGFloat
    var selected: Bool
    var expanded: Bool
    var percent: Bool
    var total: UInt64
    var fullName: Bool
    var toggle: () -> Void
    var select: () -> Void
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { id in
                if let c = Columns.all[id] {
                    cell(id)
                        .frame(maxWidth: c.width == 0 ? .infinity : c.width, alignment: c.alignRight ? .trailing : .leading)
                        .frame(minWidth: c.width == 0 ? 150 : c.width, maxWidth: c.width == 0 ? .infinity : c.width)
                        .frame(height: height)
                        .background(heat(id))
                }
            }
        }
        .padding(.leading, 6)
        .background(selected ? Color.accentColor.opacity(0.20) : (hover ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Color.accentColor).frame(width: 3, height: 16).padding(.leading, 1) }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { select(); open() }
        .onTapGesture { select() }
    }

    private func heat(_ id: String) -> Color {
        guard row.kind != .section else { return .clear }
        switch id {
        case "cpu": return Heat.color(Heat.cpu(row.cpu))
        case "memory": return Heat.color(Heat.memory(row.memory))
        case "disk": return Heat.color(Heat.disk(row.disk))
        case "network": return Heat.color(Heat.network(row.net))
        case "gpu": return Heat.color(Heat.cpu(row.gpu))
        case "power": return Heat.color(Heat.power(row.power))
        default: return .clear
        }
    }

    @ViewBuilder private func cell(_ id: String) -> some View {
        if id == "name" { nameCell }
        else if row.kind == .section { Color.clear }
        else {
            Text(text(id)).font(.system(size: 12.5)).monospacedDigit().lineLimit(1).truncationMode(.middle).padding(.horizontal, 10)
        }
    }

    private var statusText: String { row.suspended ? "Suspended" : (row.efficient ? "Efficiency mode" : "") }

    private func text(_ id: String) -> String {
        switch id {
        case "status": return statusText
        case "pid": return row.pid.map(String.init) ?? ""
        case "user": return Users.name(row.uid)
        case "cpu": return Fmt.percent(row.cpu)
        case "cpuTime": return Fmt.cpuTime(row.cpuTime)
        case "memory": return percent ? Fmt.percent(total > 0 ? Double(row.memory) / Double(total) * 100 : 0) : Fmt.megabytes(row.memory)
        case "disk": return Fmt.diskRate(row.disk)
        case "network": return Fmt.bitRate(row.net).replacingOccurrences(of: "0 bps", with: "0 Mbps")
        case "gpu": return Fmt.percent(row.gpu)
        case "power": return Fmt.power(row.power)
        case "threads": return row.threads > 0 ? "\(row.threads)" : ""
        case "arch": return row.pid == nil ? "" : (row.translated ? "x86_64 (Rosetta)" : "Apple silicon")
        case "description": return row.path
        default: return ""
        }
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 18, height: 1)
            if !row.children.isEmpty {
                Button(action: toggle) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
            if row.kind != .section {
                if row.kind == .group && row.id.hasPrefix("u:") { Image(systemName: "person.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                else { AppIcon(path: row.iconPath) }
            }
            if row.kind == .section {
                Text("\(row.name) (\(row.count))").font(.system(size: 13, weight: .semibold))
            } else {
                Text(row.name).font(.system(size: 12.5)).lineLimit(1)
                if row.kind == .group && !row.id.hasPrefix("u:") { Text("(\(row.count))").font(.system(size: 12)).foregroundStyle(.secondary) }
                if row.id.hasPrefix("u:") && row.isApp { Text("(\(fullName ? "you" : "you"))").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
    }
}

/// Window-level arrow-key handling; unlike `onKeyPress` it sees every auto-repeat event while a key is held.
@MainActor
final class KeyMonitor {
    var onKey: ((UInt16) -> Bool)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let plain = e.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, plain, let w = NSApp.keyWindow, w.attachedSheet == nil, w.sheetParent == nil,
                      !(w.firstResponder is NSText) else { return false }
                return self.onKey?(code) ?? false
            }
            return handled ? nil : e
        }
    }

    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }
}
