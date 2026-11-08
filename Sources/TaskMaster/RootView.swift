import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    var alwaysOnTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.level = alwaysOnTop ? .floating : .normal }
    }
}

struct RootView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var ui = ui
        @Bindable var monitor = monitor
        let summary = ui.graphOnly && ui.page == .performance
        HStack(spacing: 0) {
            if !summary { NavRail() }
            ZStack {
                switch ui.page {
                case .processes: ProcessesPage()
                case .performance: PerformancePage()
                case .history: HistoryPage()
                case .startup: StartupPage()
                case .users: UsersPage()
                case .details: DetailsPage()
                case .services: ServicesPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.62))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: summary ? 0 : 10))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: summary ? 0 : 10).strokeBorder(Color.primary.opacity(0.09)))
        }
        .containerBackground(.regularMaterial, for: .window)
        .background(WindowAccessor(alwaysOnTop: settings.alwaysOnTop))
        .searchable(text: $ui.search, placement: .toolbar, prompt: "Type a name, publisher, or PID to search")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            ui.selectFirstTick += 1
        }
        .onChange(of: ui.searchFocusTick) { _, _ in
            searchFocused = true
            if let item = NSApp.keyWindow?.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first { item.beginSearchInteraction() }
        }
        .navigationTitle("TaskMaster")
        .sheet(isPresented: $ui.showRunSheet) { RunTaskSheet() }
        .sheet(item: $ui.properties) { PropertiesSheet(target: $0) }
        .alert(item: $monitor.alert) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("OK"))) }
        .alert("Warning: ending a system process", isPresented: Binding(get: { monitor.pendingEnd != nil }, set: { if !$0 { monitor.pendingEnd = nil } }),
               presenting: monitor.pendingEnd) { req in
            Button("End process", role: .destructive) { monitor.perform(req) }
            Button("Cancel", role: .cancel) {}
        } message: { req in
            Text("Ending “\(req.name)” can cause undesired results including loss of unsaved data and system instability. Are you sure you want to end it?")
        }
        .preferredColorScheme(settings.theme.scheme)
        .onChange(of: ui.page) { _, _ in ui.search = "" }
    }
}

struct NavRail: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        let expanded = settings.railExpanded
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { settings.railExpanded.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 14)).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(expanded ? "Hide navigation" : "Expand navigation")
            ForEach(Page.main) { item($0, expanded) }
            Spacer()
            item(.settings, expanded)
        }
        .padding(.horizontal, 6).padding(.bottom, 8).padding(.top, 2)
        .frame(width: expanded ? 216 : 52)
    }

    private func item(_ p: Page, _ expanded: Bool) -> some View {
        let selected = ui.page == p
        return Button { ui.page = p } label: {
            HStack(spacing: 12) {
                Image(systemName: p.symbol).font(.system(size: 15)).frame(width: 24)
                if expanded { Text(p.title).font(.system(size: 13)).lineLimit(1); Spacer(minLength: 0) }
            }
            .padding(.horizontal, 6).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.09) : .clear))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Color.accentColor).frame(width: 3, height: 18).offset(x: -3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "" : p.title)
    }
}
