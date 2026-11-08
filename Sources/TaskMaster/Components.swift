import SwiftUI
import AppKit

// MARK: - Icons

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func image(for path: String) -> NSImage {
        if let c = cache[path] { return c }
        let img = path.isEmpty ? NSWorkspace.shared.icon(for: .unixExecutable) : NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 20, height: 20)
        cache[path] = img
        return img
    }
}

struct AppIcon: View {
    var path: String
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: Icons.image(for: path)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

// MARK: - Buttons (Windows 11 command-bar style)

struct CommandButton: View {
    var title: String?
    var symbol: String
    var disabled = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13))
                if let title { Text(title).font(.system(size: 12.5)) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover && !disabled ? Color.primary.opacity(0.07) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

struct AccentButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.regular)
    }
}

// MARK: - Page header

struct PageHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold)).padding(.trailing, 12)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20).frame(height: 52)
    }
}

// MARK: - Stats

struct StatBlock: View {
    var label: String
    var value: String
    var large = false
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: large ? 26 : 13, weight: large ? .light : .regular)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct InfoRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.system(size: 12.5))
    }
}

// MARK: - Graph

struct GraphView: View {
    var series: [[Double]]
    var colors: [Color]
    var maxValue: Double = 100
    var tick: Int = 0
    var mini = false
    var dashed: Set<Int> = []
    var color: Color { colors.first ?? .accentColor }

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(color.opacity(mini ? 0.07 : 0.05)))
            let n = series.first?.count ?? 0
            let dx = n > 1 ? size.width / CGFloat(n - 1) : size.width
            if !mini {
                let grid = color.opacity(0.22)
                for i in 1..<10 {
                    var p = Path(); let y = size.height * CGFloat(i) / 10
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(grid), lineWidth: 0.5)
                }
                var s = (tick / 6) * 6
                while s > tick - n {
                    let x = size.width - CGFloat(tick - s) * dx
                    if x > 0 && x < size.width {
                        var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(grid), lineWidth: 0.5)
                    }
                    s -= 6
                }
            }
            for (idx, values) in series.enumerated() {
                guard values.count > 1 else { continue }
                var line = Path()
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * dx, y: size.height - CGFloat(min(max(v / max(maxValue, 0.0001), 0), 1)) * (size.height - 1) - 0.5)
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                let c = colors[min(idx, colors.count - 1)]
                if !dashed.contains(idx) {
                    var fill = line
                    fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [c.opacity(0.38), c.opacity(0.12)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                ctx.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: mini ? 1 : 1.5, lineJoin: .round, dash: dashed.contains(idx) ? [4, 3] : []))
            }
            ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.9)), lineWidth: 1)
        }
    }
}

/// Graph with the Task Manager caption row ("% Utilization … 100%", "60 seconds … 0").
struct GraphCard: View {
    var title: String
    var maxLabel: String
    var series: [[Double]]
    var colors: [Color]
    var maxValue: Double = 100
    var tick: Int
    var height: CGFloat = 220
    var dashed: Set<Int> = []

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(maxLabel).foregroundStyle(.secondary)
            }.font(.system(size: 11.5))
            GraphView(series: series, colors: colors, maxValue: maxValue, tick: tick, dashed: dashed).frame(height: height)
            HStack {
                Text("60 seconds").foregroundStyle(.secondary)
                Spacer()
                Text("0").foregroundStyle(.secondary)
            }.font(.system(size: 11.5))
        }
    }
}

// MARK: - Misc

struct Pill: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

extension View {
    func card(radius: CGFloat = 8) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.08)))
    }
}
