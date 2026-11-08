import SwiftUI

struct DataColumn<Item>: Identifiable {
    var id: String
    var title: String
    var width: CGFloat = 0           // 0 = flexible
    var right = false
    var text: (Item) -> String
    var number: ((Item) -> Double)?
    var icon: ((Item) -> String)?    // path for AppIcon
    var symbol: String?              // SF symbol for leading glyph
}

struct DataTable<Item: Identifiable, Menu: View>: View where Item.ID == String {
    var items: [Item]
    var columns: [DataColumn<Item>]
    var selection: Binding<String?>
    var rowHeight: CGFloat = 36
    @Environment(UIState.self) private var ui
    @State private var sortID: String?
    @State private var ascending = true
    @ViewBuilder var menu: (Item) -> Menu

    private var sorted: [Item] {
        guard let id = sortID, let c = columns.first(where: { $0.id == id }) else { return items }
        let r = items.sorted { a, b in
            if let n = c.number { return n(a) < n(b) }
            return c.text(a).localizedCaseInsensitiveCompare(c.text(b)) == .orderedAscending
        }
        return ascending ? r : r.reversed()
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    rowsView
                } header: {
                    VStack(spacing: 0) { headerView; Divider() }
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .onChange(of: ui.selectFirstTick) { _, _ in
            if let first = sorted.first { selection.wrappedValue = first.id; proxy.scrollTo(first.id) }
        }
        }
    }

    private var headerView: some View {
            HStack(spacing: 0) {
                ForEach(columns) { c in
                    Button {
                        if sortID == c.id { ascending.toggle() } else { sortID = c.id; ascending = true }
                    } label: {
                        HStack(spacing: 3) {
                            if c.right { Spacer(minLength: 0) }
                            Text(c.title).font(.system(size: 12))
                            if sortID == c.id { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: c.right ? .trailing : .leading).frame(height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: c.width == 0 ? 150 : c.width, maxWidth: c.width == 0 ? .infinity : c.width)
                }
            }.padding(.leading, 6)
    }

    private var rowsView: some View {
                    ForEach(sorted) { item in
                        let selected = selection.wrappedValue == item.id
                        HStack(spacing: 0) {
                            ForEach(columns) { c in
                                HStack(spacing: 8) {
                                    if c.right { Spacer(minLength: 0) }
                                    if let p = c.icon?(item) { AppIcon(path: p) }
                                    else if let s = c.symbol { Image(systemName: s).foregroundStyle(.secondary).frame(width: 18) }
                                    Text(c.text(item)).font(.system(size: 12.5)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                                }
                                .padding(.horizontal, 10)
                                .frame(minWidth: c.width == 0 ? 150 : c.width, maxWidth: c.width == 0 ? .infinity : c.width, alignment: c.right ? .trailing : .leading)
                            }
                        }
                        .padding(.leading, 6).frame(height: rowHeight)
                        .background(selected ? Color.accentColor.opacity(0.20) : .clear)
                        .overlay(alignment: .leading) { if selected { Capsule().fill(Color.accentColor).frame(width: 3, height: 16).padding(.leading, 1) } }
                        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
                        .contentShape(Rectangle())
                        .onTapGesture { selection.wrappedValue = item.id }
                        .contextMenu { menu(item) }
                    }
    }
}
