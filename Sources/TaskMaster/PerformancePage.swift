import SwiftUI

struct PerformancePage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(spacing: 0) {
            if !ui.graphOnly {
                PageHeader(title: "Performance") {
                    CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { ui.showRunSheet = true }
                    CommandButton(title: ui.graphOnly ? "Full view" : "Graph summary view", symbol: "rectangle.compress.vertical") { ui.graphOnly.toggle() }
                    ViewMenu(tree: false)
                }
            }
            HStack(spacing: 0) {
                if !ui.graphOnly {
                    ResourceList().frame(width: 236)
                    Divider()
                }
                ResourceDetail()
                    .onTapGesture(count: 2) { ui.graphOnly.toggle() }
            }
        }
        .onAppear { validateSelection() }
    }

    private func validateSelection() {
        let s = monitor.snapshot
        switch ui.perf {
        case .disk(let i) where !s.disks.contains { $0.id == i }: ui.perf = .cpu
        case .network(let b) where !s.nets.contains { $0.bsd == b }: ui.perf = .cpu
        default: break
        }
    }
}

// MARK: - Left list

private struct ResourceList: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @State private var keys = KeyMonitor()

    private var order: [PerfItem] {
        let s = monitor.snapshot
        return [.cpu, .memory] + s.disks.map { .disk($0.id) } + s.nets.map { .network($0.bsd) } + [.gpu]
    }

    private func handleKey(_ code: UInt16) -> Bool {
        guard code == 125 || code == 126 else { return false }
        let items = order
        let d = code == 125 ? 1 : -1
        let idx = items.firstIndex(of: ui.perf) ?? 0
        ui.perf = items[min(max(idx + d, 0), items.count - 1)]
        return true
    }

    var body: some View {
        let s = monitor.snapshot
        ScrollView {
            VStack(spacing: 2) {
                item(.cpu, "CPU", Fmt.percent(s.cpu), [monitor.cpuHistory], [.tmCPU], 100)
                item(.memory, "Memory", "\(Fmt.bytes(s.mem.used))/\(Fmt.bytes(s.mem.total, decimals: 0)) (\(Fmt.percent(Double(s.mem.used) / Double(max(s.mem.total, 1)) * 100)))",
                     [monitor.memHistory], [.tmMemory], 100)
                ForEach(s.disks) { d in
                    item(.disk(d.id), "Disk \(d.index)", "\(d.kind)\n\(Fmt.percent(d.active))", [monitor.diskActive[d.id] ?? []], [.tmDisk], 100)
                }
                ForEach(s.nets) { n in
                    let down = monitor.netDown[n.bsd] ?? [], up = monitor.netUp[n.bsd] ?? []
                    item(.network(n.bsd), n.title, "S: \(Fmt.bitRate(n.upBps)) R: \(Fmt.bitRate(n.downBps))",
                         [down, up], [.tmNetwork, .tmNetwork], max(down.max() ?? 0, up.max() ?? 0, 12_500.0))
                }
                item(.gpu, "GPU 0", "\(s.gpu.name)\n\(Fmt.percent(s.gpu.utilization))", [monitor.gpuHistory], [.tmGPU], 100)
            }.padding(8)
        }
        .onAppear {
            keys.onKey = { code in handleKey(code) }
            keys.start()
        }
        .onDisappear { keys.stop() }
    }

    private func item(_ id: PerfItem, _ title: String, _ sub: String, _ series: [[Double]], _ colors: [Color], _ max: Double) -> some View {
        let selected = ui.perf == id
        return Button { ui.perf = id } label: {
            HStack(spacing: 10) {
                GraphView(series: series, colors: colors, maxValue: max, mini: true, dashed: series.count > 1 ? [1] : []).frame(width: 66, height: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.10) : .clear))
            .overlay(alignment: .leading) { if selected { Capsule().fill(Color.accentColor).frame(width: 3, height: 22).offset(x: -3) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Right detail

private struct ResourceDetail: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch ui.perf {
                case .cpu: CPUDetail()
                case .memory: MemoryDetail()
                case .disk(let id): DiskDetail(id: id)
                case .network(let b): NetworkDetail(bsd: b)
                case .gpu: GPUDetail()
                }
            }.padding(20)
        }
    }
}

private struct DetailTitle: View {
    var title: String
    var subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 24, weight: .semibold))
            Spacer()
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct CPUDetail: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        let s = monitor.snapshot, i = monitor.info
        DetailTitle(title: "CPU", subtitle: i.chip)
        VStack(spacing: 3) {
            HStack {
                Text(ui.cpuLogical ? "% Utilization over 60 seconds, per logical processor" : "% Utilization").foregroundStyle(.secondary)
                Spacer()
                Text("100%").foregroundStyle(.secondary)
            }.font(.system(size: 11.5))
            if ui.cpuLogical {
                let cols = s.cores.count <= 4 ? 2 : (s.cores.count <= 16 ? 4 : 6)
                let rows = (s.cores.count + cols - 1) / max(cols, 1)
                let cell = (240 - CGFloat(max(rows - 1, 0)) * 4) / CGFloat(max(rows, 1))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                    ForEach(Array(monitor.coreHistory.enumerated()), id: \.offset) { idx, h in
                        GraphView(series: [h], colors: [.tmCPU], tick: monitor.tick, mini: true).frame(height: cell)
                            .overlay(alignment: .topLeading) { Text("\(idx)").font(.system(size: 9)).foregroundStyle(.secondary).padding(3) }
                    }
                }.frame(height: 240)
            } else {
                GraphView(series: [monitor.cpuHistory], colors: [.tmCPU], tick: monitor.tick).frame(height: 240)
            }
            HStack { Text("60 seconds").foregroundStyle(.secondary); Spacer(); Text("0").foregroundStyle(.secondary) }.font(.system(size: 11.5))
        }
        .contextMenu {
            Menu("Change graph to") {
                Button("Overall utilization") { ui.cpuLogical = false }
                Button("Logical processors") { ui.cpuLogical = true }
            }
            Button("Graph summary view") { ui.graphOnly.toggle() }
        }
        HStack(alignment: .top, spacing: 40) {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                GridRow {
                    StatBlock(label: "Utilization", value: Fmt.percent(s.cpu), large: true)
                    StatBlock(label: "P-cores", value: "\(i.performanceCores)", large: true)
                    StatBlock(label: "E-cores", value: "\(i.efficiencyCores)", large: true)
                }
                GridRow {
                    StatBlock(label: "Processes", value: "\(s.procs.count)", large: true)
                    StatBlock(label: "Threads", value: "\(s.threads)", large: true)
                    StatBlock(label: "Handles", value: "\(s.handles)", large: true)
                }
                GridRow { StatBlock(label: "Up time", value: Fmt.uptime(s.uptime), large: true).gridCellColumns(3) }
            }
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Cores:", value: "\(i.performanceCores + i.efficiencyCores)")
                InfoRow(label: "Logical processors:", value: "\(i.logical)")
                InfoRow(label: "Virtualization:", value: i.virtualization ? "Enabled" : "Disabled")
                InfoRow(label: "L1 cache:", value: i.l1d > 0 ? "\(Fmt.bytes(UInt64(i.l1d), decimals: 0)) data + \(Fmt.bytes(UInt64(i.l1i), decimals: 0)) instruction (P)" : "N/A")
                InfoRow(label: "L2 cache:", value: i.l2 > 0 ? "\(Fmt.bytes(UInt64(i.l2), decimals: 0)) (P cluster)" : "N/A")
                InfoRow(label: "Thermal state:", value: thermal)
                InfoRow(label: "Model:", value: i.model)
            }
        }
    }

    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

private struct MemoryDetail: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot, m = s.mem
        DetailTitle(title: "Memory", subtitle: "\(Fmt.bytes(m.total, decimals: 0)) unified memory")
        GraphCard(title: "Memory usage", maxLabel: Fmt.bytes(m.total, decimals: 0), series: [monitor.memHistory], colors: [.tmMemory], tick: monitor.tick, height: 200)
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory composition").font(.system(size: 11.5)).foregroundStyle(.secondary)
            CompositionBar(mem: m).frame(height: 44)
            HStack(spacing: 14) {
                legend("App", .tmMemory.opacity(0.95)); legend("Wired", .tmMemory.opacity(0.7)); legend("Compressed", .tmMemory.opacity(0.45))
                legend("Cached", .tmMemory.opacity(0.22)); legend("Free", .clear)
            }
        }
        HStack(alignment: .top, spacing: 40) {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                GridRow {
                    StatBlock(label: "In use (Compressed)", value: "\(Fmt.bytes(m.used)) (\(Fmt.bytes(m.compressed)))", large: true)
                    StatBlock(label: "Available", value: Fmt.bytes(m.available), large: true)
                }
                GridRow {
                    StatBlock(label: "Committed", value: "\(Fmt.bytes(m.used + m.swapUsed, decimals: 1))/\(Fmt.bytes(m.total + m.swapTotal, decimals: 1))", large: true)
                    StatBlock(label: "Cached", value: Fmt.bytes(m.cached), large: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "App memory:", value: Fmt.bytes(m.app))
                InfoRow(label: "Wired:", value: Fmt.bytes(m.wired))
                InfoRow(label: "Compressed:", value: Fmt.bytes(m.compressed))
                InfoRow(label: "Swap used:", value: "\(Fmt.bytes(m.swapUsed)) of \(Fmt.bytes(m.swapTotal))")
                InfoRow(label: "Memory pressure:", value: m.pressure >= 4 ? "Critical" : (m.pressure == 2 ? "Warning" : "Normal"))
                InfoRow(label: "Form factor:", value: "Unified (on package)")
            }
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.tmMemory)).frame(width: 10, height: 10)
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct CompositionBar: View {
    var mem: MemSample
    var body: some View {
        GeometryReader { g in
            let total = Double(max(mem.total, 1))
            let parts: [(Double, Double)] = [(Double(mem.app), 0.95), (Double(mem.wired), 0.7), (Double(mem.compressed), 0.45), (Double(mem.cached), 0.22)]
            HStack(spacing: 0) {
                ForEach(0..<parts.count, id: \.self) { i in
                    Rectangle().fill(Color.tmMemory.opacity(parts[i].1)).frame(width: g.size.width * parts[i].0 / total)
                }
                Spacer(minLength: 0)
            }
            .background(Color.tmMemory.opacity(0.05))
            .overlay(Rectangle().stroke(Color.tmMemory, lineWidth: 1))
        }
    }
}

private struct DiskDetail: View {
    @Environment(Monitor.self) private var monitor
    var id: UInt64

    var body: some View {
        if let d = monitor.snapshot.disks.first(where: { $0.id == id }) {
            let r = monitor.diskRead[id] ?? [], w = monitor.diskWrite[id] ?? []
            let peak = max(r.max() ?? 0, w.max() ?? 0, 1_048_576.0)
            DetailTitle(title: "Disk \(d.index)", subtitle: d.name)
            GraphCard(title: "Active time", maxLabel: "100%", series: [monitor.diskActive[id] ?? []], colors: [.tmDisk], tick: monitor.tick, height: 170)
            GraphCard(title: "Disk transfer rate", maxLabel: Fmt.diskRate(peak).replacingOccurrences(of: ".0 MB/s", with: " MB/s"), series: [r, w], colors: [.tmDisk, .tmDisk],
                      maxValue: peak, tick: monitor.tick, height: 90, dashed: [1])
            HStack(alignment: .top, spacing: 40) {
                Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                    GridRow {
                        StatBlock(label: "Active time", value: Fmt.percent(d.active), large: true)
                        StatBlock(label: "Average response time", value: String(format: "%.1f ms", d.responseMs), large: true)
                    }
                    GridRow {
                        StatBlock(label: "Read speed", value: Fmt.diskRate(d.readBps), large: true)
                        StatBlock(label: "Write speed", value: Fmt.diskRate(d.writeBps), large: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Capacity:", value: d.capacity > 0 ? Fmt.bytes(d.capacity, decimals: 0) : "N/A")
                    InfoRow(label: "Type:", value: d.kind)
                    InfoRow(label: "Model:", value: d.name)
                }
            }
        } else { Text("Disk unavailable").foregroundStyle(.secondary) }
    }
}

private struct NetworkDetail: View {
    @Environment(Monitor.self) private var monitor
    var bsd: String

    var body: some View {
        if let n = monitor.snapshot.nets.first(where: { $0.bsd == bsd }) {
            let down = monitor.netDown[bsd] ?? [], up = monitor.netUp[bsd] ?? []
            let peak = max(down.max() ?? 0, up.max() ?? 0, 12_500.0)
            DetailTitle(title: n.title, subtitle: n.subtitle)
            GraphCard(title: "Throughput", maxLabel: Fmt.bitRate(peak), series: [down, up], colors: [.tmNetwork, .tmNetwork], maxValue: peak,
                      tick: monitor.tick, height: 220, dashed: [1])
            HStack(alignment: .top, spacing: 40) {
                Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                    GridRow {
                        StatBlock(label: "Send", value: Fmt.bitRate(n.upBps), large: true, color: .tmNetwork)
                        StatBlock(label: "Receive", value: Fmt.bitRate(n.downBps), large: true, color: .tmNetwork)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Adapter name:", value: n.bsd)
                    if n.isWiFi { InfoRow(label: "SSID:", value: n.ssid.isEmpty ? "Hidden (Location access required)" : n.ssid) }
                    InfoRow(label: "Connection type:", value: n.isWiFi ? "Wi-Fi" : "Ethernet")
                    if n.linkSpeed > 0 { InfoRow(label: "Link speed:", value: String(format: "%.0f Mbps", n.linkSpeed / 1e6)) }
                    InfoRow(label: "IPv4 address:", value: n.ipv4.isEmpty ? "—" : n.ipv4)
                    InfoRow(label: "IPv6 address:", value: n.ipv6.isEmpty ? "—" : n.ipv6)
                    if n.isWiFi && n.rssi != 0 { InfoRow(label: "Signal strength:", value: "\(n.rssi) dBm") }
                }
            }
        } else { Text("Network adapter unavailable").foregroundStyle(.secondary) }
    }
}

private struct GPUDetail: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let g = monitor.snapshot.gpu, total = monitor.info.memory
        DetailTitle(title: "GPU 0", subtitle: g.name)
        GraphCard(title: "Utilization", maxLabel: "100%", series: [monitor.gpuHistory], colors: [.tmGPU], tick: monitor.tick, height: 190)
        GraphCard(title: "Shared GPU memory usage", maxLabel: Fmt.bytes(total, decimals: 0), series: [monitor.gpuMemHistory], colors: [.tmGPU], tick: monitor.tick, height: 100)
        HStack(alignment: .top, spacing: 40) {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                GridRow {
                    StatBlock(label: "Utilization", value: Fmt.percent(g.utilization), large: true)
                    StatBlock(label: "Shared GPU memory", value: "\(Fmt.bytes(g.memoryInUse))/\(Fmt.bytes(total, decimals: 0))", large: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Driver:", value: "Apple GPU (unified memory)")
                if g.cores > 0 { InfoRow(label: "GPU cores:", value: "\(g.cores)") }
                InfoRow(label: "Allocated memory:", value: Fmt.bytes(g.memoryAllocated))
            }
        }
    }
}
