import SwiftUI
import AppKit

struct RunTaskSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    @State private var command = ""
    @State private var admin = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                Text("Create new task").font(.system(size: 17, weight: .semibold))
            }
            Text("Type the name of a program, folder, document, or Internet resource, and TaskMaster will open it for you.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Open:")
                TextField("", text: $command).textFieldStyle(.roundedBorder).focused($focused).onSubmit(ok)
                Button("Browse…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    if p.runModal() == .OK, let u = p.url { command = u.path }
                }
            }
            Toggle("Create this task with administrator privileges", isOn: $admin)
            HStack {
                Spacer()
                Button("Cancel") { ui.showRunSheet = false }.keyboardShortcut(.cancelAction)
                Button("OK", action: ok).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 480)
        .onAppear { focused = true }
    }

    private func ok() {
        monitor.runNewTask(command, admin: admin)
        ui.showRunSheet = false
    }
}

struct PropertiesSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(UIState.self) private var ui
    var target: PropertiesTarget

    var body: some View {
        let url = URL(fileURLWithPath: target.path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let proc = target.pid.flatMap { monitor.process($0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIcon(path: target.path, size: 40)
                Text(target.name).font(.system(size: 17, weight: .semibold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                InfoRow(label: "Type:", value: url.pathExtension == "app" ? "Application" : (target.path.isEmpty ? "System process" : "Unix executable"))
                InfoRow(label: "Location:", value: target.path.isEmpty ? "—" : url.deletingLastPathComponent().path)
                InfoRow(label: "Size:", value: (attrs?[.size] as? UInt64).map { Fmt.bytes($0) } ?? "—")
                InfoRow(label: "Date modified:", value: (attrs?[.modificationDate] as? Date)?.formatted(date: .long, time: .shortened) ?? "—")
                InfoRow(label: "Publisher:", value: target.path.isEmpty ? "—" : (Startup.publisher(for: target.path).isEmpty ? "Unsigned" : Startup.publisher(for: target.path)))
                if let b = TreeBuilder.bundle(target.path).flatMap({ Bundle(path: $0) }) {
                    InfoRow(label: "Bundle identifier:", value: b.bundleIdentifier ?? "—")
                    InfoRow(label: "Version:", value: b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                if let p = proc {
                    InfoRow(label: "PID:", value: "\(p.pid)")
                    InfoRow(label: "Parent PID:", value: "\(p.ppid)")
                    InfoRow(label: "User name:", value: Users.name(p.uid))
                    InfoRow(label: "Started:", value: p.startTime.formatted(date: .abbreviated, time: .standard))
                    InfoRow(label: "Architecture:", value: p.translated ? "x86_64 (Rosetta)" : "Apple silicon")
                    InfoRow(label: "Threads:", value: "\(p.threads)")
                    InfoRow(label: "Memory:", value: Fmt.bytes(p.memory))
                }
            }
            HStack {
                Button("Open file location") { monitor.reveal(path: target.path) }.disabled(target.path.isEmpty)
                Spacer()
                Button("OK") { ui.properties = nil }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 520)
    }
}
