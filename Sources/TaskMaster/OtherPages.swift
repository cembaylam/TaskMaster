import SwiftUI
import AppKit

// MARK: - App history

struct HistoryRow: Identifiable { var id: String; var e: HistoryEntry }

struct HistoryPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var ui = ui
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        let rows = monitor.history.entries.filter { settings.showAllHistory || $0.value.isApp }
            .filter { q.isEmpty || $0.value.name.localizedCaseInsensitiveContains(q) }
            .map { HistoryRow(id: $0.key, e: $0.value) }
        VStack(spacing: 0) {
            PageHeader(title: "App history") {
                CommandButton(title: "Delete usage history", symbol: "trash") { monitor.resetHistory() }
                ViewMenu(tree: false)
            }
            HStack {
                Text("Resource usage since \(monitor.history.since.formatted(date: .abbreviated, time: .shortened)) for \(Users.name(getuid())) while TaskMaster was running.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 8)
            DataTable(items: rows, columns: [
                DataColumn(id: "name", title: "Name", text: { $0.e.name }, icon: { $0.e.path }),
                DataColumn(id: "cpu", title: "CPU time", width: 130, right: true, text: { Fmt.cpuTime($0.e.cpu) }, number: { $0.e.cpu }),
                DataColumn(id: "net", title: "Network", width: 130, right: true, text: { Fmt.bytes($0.e.net) }, number: { Double($0.e.net) }),
                DataColumn(id: "disk", title: "Disk I/O", width: 130, right: true, text: { Fmt.bytes($0.e.disk) }, number: { Double($0.e.disk) }),
            ], selection: $ui.historySelection) { row in
                Button("Open file location") { monitor.reveal(path: row.e.path) }
                Button("Search online") { monitor.searchOnline(row.e.name) }
            }
        }
    }
}

// MARK: - Startup apps

struct StartupPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        let items = monitor.startupItems.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.publisher.localizedCaseInsensitiveContains(q) }
        let selected = monitor.startupItems.first { $0.id == ui.startupSelection }
        VStack(spacing: 0) {
            PageHeader(title: "Startup apps") {
                if let s = selected {
                    CommandButton(title: s.enabled ? "Disable" : "Enable", symbol: s.enabled ? "nosign" : "checkmark.circle") {
                        monitor.setStartup(s, enabled: !s.enabled)
                    }
                }
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { ui.showRunSheet = true }
                CommandButton(title: nil, symbol: "arrow.clockwise") { monitor.refreshStartup() }
            }
            HStack {
                Text("Last boot: \(Sys.bootTime.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 8)
            DataTable(items: items, columns: [
                DataColumn(id: "name", title: "Name", text: { $0.name }, icon: { item in
                    let p = item.kind == .loginItem ? item.path : (TreeBuilder.bundle(item.program) ?? item.program)
                    return FileManager.default.fileExists(atPath: p) ? p : "" }),
                DataColumn(id: "pub", title: "Publisher", width: 200, text: { $0.publisher }),
                DataColumn(id: "status", title: "Status", width: 110, text: { $0.enabled ? "Enabled" : "Disabled" }),
                DataColumn(id: "impact", title: "Startup impact", width: 140, text: { monitor.impact(for: $0) }),
                DataColumn(id: "kind", title: "Type", width: 120, text: { $0.kind == .loginItem ? "Login item" : ($0.kind == .agent ? "Launch agent" : "Launch daemon") }),
            ], selection: $ui.startupSelection) { s in
                Button(s.enabled ? "Disable" : "Enable") { monitor.setStartup(s, enabled: !s.enabled) }
                Button("Open file location") { monitor.reveal(path: s.path) }
                Button("Search online") { monitor.searchOnline(s.name) }
                Button("Properties") { ui.properties = PropertiesTarget(name: s.name, path: s.program.isEmpty ? s.path : s.program, pid: nil) }
            }
        }
        .task { if !monitor.startupLoaded { monitor.refreshStartup() } }
    }
}

// MARK: - Services

struct ServicesPage: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        let items = monitor.services.filter { q.isEmpty || $0.label.localizedCaseInsensitiveContains(q) || $0.program.localizedCaseInsensitiveContains(q) }
        let selected = monitor.services.first { $0.id == ui.serviceSelection }
        VStack(spacing: 0) {
            PageHeader(title: "Services") {
                CommandButton(title: "Start", symbol: "play.fill", disabled: selected == nil || selected!.running) { run(selected, Launchd.start) }
                CommandButton(title: "Stop", symbol: "stop.fill", disabled: selected == nil || !selected!.running) { run(selected, Launchd.stop) }
                CommandButton(title: "Restart", symbol: "arrow.triangle.2.circlepath", disabled: selected == nil) { run(selected, Launchd.restart) }
                CommandButton(title: nil, symbol: "arrow.clockwise") { monitor.refreshServices() }
            }
            DataTable(items: items, columns: [
                DataColumn(id: "name", title: "Name", width: 330, text: { $0.label }, symbol: "gearshape"),
                DataColumn(id: "pid", title: "PID", width: 80, right: true, text: { $0.pid.map(String.init) ?? "" }, number: { Double($0.pid ?? 0) }),
                DataColumn(id: "desc", title: "Description", text: { $0.program }),
                DataColumn(id: "status", title: "Status", width: 100, text: { $0.running ? "Running" : "Stopped" }),
                DataColumn(id: "group", title: "Group", width: 90, text: { $0.group }),
            ], selection: $ui.serviceSelection, rowHeight: 30) { s in
                Button("Start") { run(s, Launchd.start) }.disabled(s.running)
                Button("Stop") { run(s, Launchd.stop) }.disabled(!s.running)
                Button("Restart") { run(s, Launchd.restart) }
                Divider()
                if let pid = s.pid { Button("Go to details") { ui.goToDetails(pid: pid) } }
                if let p = s.plistPath { Button("Open file location") { monitor.reveal(path: p) } }
                Button("Search online") { monitor.searchOnline(s.label) }
            }
        }
        .task {
            monitor.refreshServices()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                monitor.refreshServices()
            }
        }
    }

    private func run(_ s: ServiceItem?, _ op: @escaping (ServiceItem) async -> String?) {
        guard let s else { return }
        Task {
            if let err = await op(s), !err.isEmpty { monitor.alert = AlertMessage(title: "Unable to change \(s.label)", message: err) }
            monitor.refreshServices()
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            PageHeader(title: "Settings") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    group("Default start page")
                    row("Choose the page TaskMaster opens on", "rectangle.on.rectangle") {
                        Picker("", selection: $settings.startPage) { ForEach(Page.main) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 180)
                    }
                    group("Real time update speed")
                    row("Choose how often the data refreshes", "speedometer") {
                        Picker("", selection: $settings.updateSpeed) { ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 180)
                    }
                    group("Window management")
                    row("Always on top", "pin") { Toggle("", isOn: $settings.alwaysOnTop).labelsHidden().toggleStyle(.switch) }
                    group("Other options")
                    row("Show full account name", "person.text.rectangle") { Toggle("", isOn: $settings.showFullAccountName).labelsHidden().toggleStyle(.switch) }
                    row("Show history for all processes", "clock.arrow.circlepath") { Toggle("", isOn: $settings.showAllHistory).labelsHidden().toggleStyle(.switch) }
                    row("Show memory as a percentage", "percent") { Toggle("", isOn: $settings.memoryAsPercent).labelsHidden().toggleStyle(.switch) }
                    row("Warn before ending system processes", "exclamationmark.triangle") { Toggle("", isOn: $settings.confirmSystemKill).labelsHidden().toggleStyle(.switch) }
                    group("Theme")
                    row("Choose the app theme", "paintbrush") {
                        Picker("", selection: $settings.theme) { ForEach(ThemeChoice.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 180)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func group(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).padding(.top, 14).padding(.bottom, 2)
    }

    private func row<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer()
            control()
        }.padding(.horizontal, 16).frame(height: 52).card()
    }
}
