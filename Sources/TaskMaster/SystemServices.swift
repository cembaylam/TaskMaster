import Foundation
import AppKit
import Security

// MARK: - Services

struct ServiceItem: Identifiable, Hashable, Sendable {
    var id: String { domain + "/" + label }
    var label: String
    var pid: Int32?
    var domain: String        // "system" or "gui/501"
    var plistPath: String?
    var program: String
    var running: Bool { pid != nil }
    var group: String { domain == "system" ? "System" : "User" }
}

enum Launchd {
    static var uid: UInt32 { getuid() }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) async -> (status: Int32, out: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Runs a shell command with the system's administrator prompt.
    static func runPrivileged(_ command: String) async -> String? {
        await MainActor.run {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var err: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
            return err?[NSAppleScript.errorMessage] as? String
        }
    }

    static func plistIndex() -> [String: (path: String, program: String)] {
        let dirs = ["/System/Library/LaunchDaemons", "/Library/LaunchDaemons", "/System/Library/LaunchAgents", "/Library/LaunchAgents",
                    NSHomeDirectory() + "/Library/LaunchAgents"]
        var map: [String: (String, String)] = [:]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".plist") {
                let p = d + "/" + f
                guard let dict = NSDictionary(contentsOfFile: p) as? [String: Any], let label = dict["Label"] as? String else { continue }
                let prog = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                map[label] = (p, prog)
            }
        }
        return map
    }

    static func services() async -> [ServiceItem] {
        let index = await Task.detached { plistIndex() }.value
        var out: [ServiceItem] = []
        for domain in ["system", "gui/\(uid)"] {
            let (_, text) = await run("/bin/launchctl", ["print", domain])
            var inServices = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("\tservices = {") { inServices = true; continue }
                if inServices && line == "\t}" { break }
                guard inServices else { continue }
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard f.count >= 3 else { continue }
                let label = f[2...].joined(separator: " ")
                let pid = Int32(f[0]).flatMap { $0 > 0 ? $0 : nil }
                let info = index[label]
                out.append(ServiceItem(label: label, pid: pid, domain: domain, plistPath: info?.path, program: info?.program ?? ""))
            }
        }
        return out
    }

    static func start(_ s: ServiceItem) async -> String? {
        let cmd = "/bin/launchctl kickstart \(s.domain)/\(s.label)"
        return await perform(s, cmd)
    }
    static func stop(_ s: ServiceItem) async -> String? { await perform(s, "/bin/launchctl kill SIGTERM \(s.domain)/\(s.label)") }
    static func restart(_ s: ServiceItem) async -> String? { await perform(s, "/bin/launchctl kickstart -k \(s.domain)/\(s.label)") }

    private static func perform(_ s: ServiceItem, _ cmd: String) async -> String? {
        if s.domain == "system" && uid != 0 { return await runPrivileged(cmd) }
        let parts = cmd.split(separator: " ").map(String.init)
        let (st, out) = await run(parts[0], Array(parts.dropFirst()))
        return st == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Startup apps

struct StartupItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case agent, daemon, loginItem }
    var id: String
    var name: String
    var publisher: String
    var kind: Kind
    var path: String              // plist or app path
    var program: String
    var label: String
    var enabled: Bool
    var domain: String
    var impact: String = "Not measured"
}

enum Startup {
    static func publisher(for path: String) -> String {
        var target = path
        if let r = path.range(of: ".app/") { target = String(path[..<r.lowerBound]) + ".app" }
        guard !target.isEmpty else { return "" }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &code) == errSecSuccess, let code else { return "" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first, let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return "" }
        if summary == "Software Signing" || summary.hasPrefix("Apple") { return "Apple Inc." }
        var s = summary
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Mac Developer: ", "3rd Party Mac Developer Application: "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if let r = s.range(of: " (", options: .backwards), s.hasSuffix(")") { s = String(s[..<r.lowerBound]) }
        return s
    }

    static func displayName(label: String, program: String) -> String {
        var p = program
        if let r = p.range(of: ".app/") { p = String(p[..<r.lowerBound]) + ".app" }
        if p.hasSuffix(".app") { return ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
        if !program.isEmpty { return (program as NSString).lastPathComponent }
        return label
    }

    static func disabledLabels() async -> Set<String> {
        var out = Set<String>()
        for d in ["gui/\(getuid())", "system"] {
            let (_, text) = await Launchd.run("/bin/launchctl", ["print-disabled", d])
            for line in text.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
                if let a = line.firstIndex(of: "\""), let b = line[line.index(after: a)...].firstIndex(of: "\"") {
                    out.insert(String(line[line.index(after: a)..<b]))
                }
            }
        }
        return out
    }

    static func agents() async -> [StartupItem] {
        let disabled = await disabledLabels()
        return await Task.detached {
            var items: [StartupItem] = []
            let dirs: [(String, StartupItem.Kind)] = [(NSHomeDirectory() + "/Library/LaunchAgents", .agent), ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon)]
            for (d, kind) in dirs {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".plist") {
                    let p = d + "/" + f
                    guard let dict = NSDictionary(contentsOfFile: p) as? [String: Any], let label = dict["Label"] as? String else { continue }
                    guard (dict["RunAtLoad"] as? Bool) == true || dict["KeepAlive"] != nil else { continue }
                    let prog = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                    items.append(StartupItem(id: p, name: displayName(label: label, program: prog), publisher: publisher(for: prog), kind: kind,
                                             path: p, program: prog, label: label, enabled: !disabled.contains(label),
                                             domain: kind == .daemon ? "system" : "gui/\(getuid())"))
                }
            }
            return items
        }.value
    }

    /// Login items set in System Settings; readable only through System Events (prompts for Automation permission once).
    static func loginItems() async -> [StartupItem] {
        let script = """
        tell application "System Events"
          set out to ""
          repeat with li in login items
            set out to out & (name of li) & "|" & (path of li) & linefeed
          end repeat
          return out
        end tell
        """
        let (st, text) = await Launchd.run("/usr/bin/osascript", ["-e", script])
        guard st == 0 else { return [] }
        return await Task.detached {
            text.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard f.count == 2 else { return nil }
                return StartupItem(id: "login:" + f[1], name: f[0], publisher: publisher(for: f[1]), kind: .loginItem, path: f[1], program: f[1],
                                   label: f[0], enabled: true, domain: "login")
            }
        }.value
    }

    static func setEnabled(_ item: StartupItem, _ on: Bool) async -> String? {
        switch item.kind {
        case .loginItem:
            if on {
                let (st, out) = await Launchd.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to make login item at end with properties {path:\"\(item.path)\", hidden:false}"])
                return st == 0 ? nil : out
            } else {
                let (st, out) = await Launchd.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete (every login item whose name is \"\(item.name)\")"])
                return st == 0 ? nil : out
            }
        case .agent, .daemon:
            let target = "\(item.domain)/\(item.label)"
            let cmd = on ? "/bin/launchctl enable \(target)" : "/bin/launchctl disable \(target)"
            if item.domain == "system" { return await Launchd.runPrivileged(cmd) }
            let parts = cmd.split(separator: " ").map(String.init)
            let (st, out) = await Launchd.run(parts[0], Array(parts.dropFirst()))
            return st == 0 ? nil : out
        }
    }
}
