import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        // stop the `top` / `nettop` helpers we spawned
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-P", "\(getpid())"]
        try? p.run()
        p.waitUntilExit()
    }
}

@main
struct TaskMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var settings: AppSettings
    @State private var monitor: Monitor
    @State private var ui: UIState

    init() {
        let s = AppSettings()
        _settings = State(initialValue: s)
        _monitor = State(initialValue: Monitor(settings: s))
        _ui = State(initialValue: UIState(start: s.startPage))
    }

    var body: some Scene {
        Window("TaskMaster", id: "main") {
            RootView()
                .environment(settings).environment(monitor).environment(ui)
                .frame(minWidth: 1040, minHeight: 580)
                .task { monitor.start() }
        }
        .defaultSize(width: 1140, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Run New Task…") { ui.showRunSheet = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { ui.searchFocusTick += 1 }.keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Process") {
                Button("End Task") { endSelected() }.keyboardShortcut(.delete, modifiers: .command)
                Button("Toggle Efficiency Mode") { efficiencySelected() }.keyboardShortcut("e")
                Button("Go to Details") { if let n = selectedNode, let p = n.pids.first { ui.goToDetails(pid: p) } }.keyboardShortcut("d")
            }
            CommandGroup(after: .toolbar) {
                Divider()
                ForEach(Array(Page.main.enumerated()), id: \.element) { i, p in
                    Button(p.title) { ui.page = p }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Button("Settings") { ui.page = .settings }.keyboardShortcut(",")
                Divider()
                Button("Refresh Now") { monitor.refreshNow() }.keyboardShortcut("r")
                Picker("Update Speed", selection: Binding(get: { settings.updateSpeed }, set: { settings.updateSpeed = $0 })) {
                    ForEach(UpdateSpeed.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Always on Top", isOn: Binding(get: { settings.alwaysOnTop }, set: { settings.alwaysOnTop = $0 }))
            }
        }
    }

    private var selectedNode: ProcNode? {
        switch ui.page {
        case .processes: findNode(monitor.sections, ui.processSelection)
        case .users: findNode(monitor.userNodes, ui.userSelection)
        case .details: ui.detailsSelection.flatMap { pid in monitor.process(pid).map { TreeBuilder.node($0, efficient: monitor.efficient) } }
        default: nil
        }
    }

    private func endSelected() { if let n = selectedNode { monitor.endNode(n) } }
    private func efficiencySelected() { if let n = selectedNode, n.kind != .section { monitor.setEfficiency(n.pids, on: !n.efficient) } }
}
