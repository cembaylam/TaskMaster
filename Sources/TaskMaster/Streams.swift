import Foundation
import Synchronization

/// Reference-type wrapper so a `Mutex` can be captured by escaping closures.
final class Locked<T: Sendable>: Sendable {
    private let m: Mutex<T>
    init(_ v: T) { m = Mutex(v) }
    func withLock<R>(_ body: (inout T) -> R) -> R { m.withLock { body(&$0) } }
}

/// Runs a long-lived command and delivers its stdout line by line.
final class LineStream: @unchecked Sendable {
    private let process = Process()
    private let buffer = Locked(Data())

    init(_ exe: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [buffer] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let lines: [String] = buffer.withLock { buf in
                buf.append(d)
                var out: [String] = []
                while let i = buf.firstIndex(of: 10) {
                    out.append(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...i)
                }
                return out
            }
            for l in lines { onLine(l) }
        }
        try? process.run()
    }

    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }
}

/// Per-process network rates from `nettop`. A streaming nettop burns >100% CPU, so we take
/// cumulative one-shot snapshots back to back (each takes ~5 s, ~1% CPU) and derive rates ourselves.
final class NetTopStream: @unchecked Sendable {
    struct Rates { var down: Double; var up: Double }
    private struct State { var latest: [Int32: Rates] = [:]; var stopped = false; var child: Int32 = 0 }
    private let state = Locked(State())

    init() {
        let st = state
        Task.detached(priority: .utility) {
            var prev: [Int32: (Double, Double)] = [:]
            var prevTime: UInt64 = 0
            while !st.withLock({ $0.stopped }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                p.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return }
                st.withLock { $0.child = p.processIdentifier }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                var cur: [Int32: (Double, Double)] = [:]
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix(",") {
                    let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                    guard parts.count >= 4, let bin = Double(parts[parts.count - 3]), let bout = Double(parts[parts.count - 2]) else { continue }
                    let name = parts[0..<(parts.count - 3)].joined(separator: ",")
                    guard let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) else { continue }
                    cur[pid] = (bin, bout)
                }
                if prevTime != 0 {
                    let dt = max(Double(now - prevTime) / 1e9, 0.5)
                    var rates: [Int32: Rates] = [:]
                    for (pid, c) in cur {
                        if let o = prev[pid] { rates[pid] = Rates(down: max(c.0 - o.0, 0) / dt, up: max(c.1 - o.1, 0) / dt) }
                    }
                    st.withLock { $0.latest = rates }
                }
                prev = cur
                prevTime = now
            }
        }
    }

    var latest: [Int32: Rates] { state.withLock { $0.latest } }
    func stop() {
        let child = state.withLock { s -> Int32 in s.stopped = true; return s.child }
        if child > 0 { kill(child, SIGTERM) }
    }
}

/// `top` is setuid-root, so it can see CPU/memory of processes libproc hides from us.
final class TopStream: @unchecked Sendable {
    struct Entry { var cpu: Double; var mem: UInt64; var threads: Int }
    private let state = Locked(State())
    private struct State { var pending: [Int32: Entry] = [:]; var latest: [Int32: Entry] = [:]; var blocks = 0 }
    private var stream: LineStream?

    init() {
        let st = state
        stream = LineStream("/usr/bin/top", ["-l", "0", "-s", "2", "-stats", "pid,cpu,mem,th"]) { line in
            if line.hasPrefix("PID") {
                st.withLock {
                    $0.blocks += 1
                    if $0.blocks > 2 { $0.latest = $0.pending }   // first block is since-boot averages
                    $0.pending = [:]
                }
                return
            }
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let pid = Int32(f[0]), let cpu = Double(f[1]) else { return }
            var m = String(f[2]).trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            var mult: Double = 1
            if let last = m.last, last.isLetter {
                switch last { case "K": mult = 1024; case "M": mult = 1048576; case "G": mult = 1073741824; default: mult = 1 }
                m.removeLast()
            }
            let th = Int(String(f[3]).split(separator: "/").first ?? "0") ?? 0
            let e = Entry(cpu: cpu, mem: UInt64((Double(m) ?? 0) * mult), threads: th)
            st.withLock { $0.pending[pid] = e }
        }
    }

    var latest: [Int32: Entry] { state.withLock { $0.latest } }
    func stop() { stream?.stop() }
}
