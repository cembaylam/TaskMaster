import SwiftUI
import Observation

enum Page: String, CaseIterable, Identifiable, Codable {
    case processes, performance, history, startup, users, details, services, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .processes: "Processes"
        case .performance: "Performance"
        case .history: "App history"
        case .startup: "Startup apps"
        case .users: "Users"
        case .details: "Details"
        case .services: "Services"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .processes: "square.grid.2x2"
        case .performance: "waveform.path.ecg.rectangle"
        case .history: "clock.arrow.circlepath"
        case .startup: "power.circle"
        case .users: "person.2"
        case .details: "list.bullet.rectangle"
        case .services: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }
    static var main: [Page] { allCases.filter { $0 != .settings } }
}

enum UpdateSpeed: String, CaseIterable, Identifiable {
    case high = "High", normal = "Normal", low = "Low", paused = "Paused"
    var id: String { rawValue }
    var seconds: Double? {
        switch self { case .high: 0.5; case .normal: 1; case .low: 4; case .paused: nil }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system = "Use system setting", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

@MainActor @Observable
final class AppSettings {
    private let d = UserDefaults.standard

    var startPage: Page { didSet { d.set(startPage.rawValue, forKey: "startPage") } }
    var updateSpeed: UpdateSpeed { didSet { d.set(updateSpeed.rawValue, forKey: "updateSpeed") } }
    var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var alwaysOnTop: Bool { didSet { d.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    var showFullAccountName: Bool { didSet { d.set(showFullAccountName, forKey: "showFullAccountName") } }
    var showAllHistory: Bool { didSet { d.set(showAllHistory, forKey: "showAllHistory") } }
    var memoryAsPercent: Bool { didSet { d.set(memoryAsPercent, forKey: "memoryAsPercent") } }
    var railExpanded: Bool { didSet { d.set(railExpanded, forKey: "railExpanded") } }
    var confirmSystemKill: Bool { didSet { d.set(confirmSystemKill, forKey: "confirmSystemKill") } }
    var detailsColumns: [String] { didSet { d.set(detailsColumns, forKey: "detailsColumns") } }

    init() {
        startPage = Page(rawValue: d.string(forKey: "startPage") ?? "") ?? .processes
        updateSpeed = UpdateSpeed(rawValue: d.string(forKey: "updateSpeed") ?? "") ?? .normal
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        alwaysOnTop = d.bool(forKey: "alwaysOnTop")
        showFullAccountName = d.bool(forKey: "showFullAccountName")
        showAllHistory = d.bool(forKey: "showAllHistory")
        memoryAsPercent = d.bool(forKey: "memoryAsPercent")
        railExpanded = d.object(forKey: "railExpanded") as? Bool ?? true
        confirmSystemKill = d.object(forKey: "confirmSystemKill") as? Bool ?? true
        detailsColumns = d.stringArray(forKey: "detailsColumns") ?? ["name", "pid", "status", "user", "cpu", "memory", "arch", "description"]
    }
}
