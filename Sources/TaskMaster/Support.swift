import Foundation
import Darwin
import SwiftUI

// MARK: - sysctl helpers

enum Sys {
    static func int(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 { return Int(v) }
        var v32: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &size, nil, 0) == 0 { return Int(v32) }
        return nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static var bootTime: Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

// MARK: - Users

enum Users {
    static func name(_ uid: UInt32) -> String {
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return String(uid)
    }

    static func fullName(_ uid: UInt32) -> String {
        if let pw = getpwuid(uid), let gecos = pw.pointee.pw_gecos {
            let s = String(cString: gecos)
            if !s.isEmpty { return s }
        }
        return name(uid)
    }
}

// MARK: - Formatting

enum Fmt {
    static func percent(_ v: Double) -> String {
        if v < 0.05 { return "0%" }
        if v < 10 { return String(format: "%.1f%%", v) }
        return String(format: "%.0f%%", v)
    }

    static func bytes(_ b: UInt64, decimals: Int = 1) -> String {
        let v = Double(b)
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024, tb = gb * 1024
        if v >= tb { return String(format: "%.\(decimals)f TB", v / tb) }
        if v >= gb { return String(format: "%.\(decimals)f GB", v / gb) }
        if v >= mb { return String(format: "%.\(decimals)f MB", v / mb) }
        if v >= kb { return String(format: "%.\(decimals)f KB", v / kb) }
        return String(format: "%.0f B", v)
    }

    /// Process-table memory: always MB like Task Manager.
    static func megabytes(_ b: UInt64) -> String {
        let mb = Double(b) / Double(1 << 20)
        if mb < 0.05 { return "0 MB" }
        if mb < 100 { return String(format: "%.1f MB", mb) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: mb)) ?? "\(Int(mb))") + " MB"
    }

    static func diskRate(_ bps: Double) -> String {
        let mb = bps / Double(1 << 20)
        if mb < 0.05 { return "0 MB/s" }
        return String(format: "%.1f MB/s", mb)
    }

    /// Network rates are shown in bits per second.
    static func bitRate(_ bytesPerSec: Double) -> String {
        let bits = bytesPerSec * 8
        if bits >= 1e9 { return String(format: "%.1f Gbps", bits / 1e9) }
        if bits >= 1e6 { return String(format: "%.1f Mbps", bits / 1e6) }
        if bits >= 1e3 { return String(format: "%.0f Kbps", bits / 1e3) }
        return bits < 1 ? "0 Mbps" : String(format: "%.0f bps", bits)
    }

    static func power(_ watts: Double) -> String {
        switch watts {
        case ..<0.05: return "Very low"
        case ..<0.5: return "Low"
        case ..<1.5: return "Moderate"
        case ..<4: return "High"
        default: return "Very high"
        }
    }

    static func cpuTime(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func uptime(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%d:%02d:%02d:%02d", t / 86400, (t / 3600) % 24, (t / 60) % 60, t % 60)
    }
}

// MARK: - Heat map

enum Heat {
    static func level(_ v: Double, _ thresholds: [Double]) -> Int {
        var l = 0
        for t in thresholds where v >= t { l += 1 }
        return l
    }

    static func cpu(_ v: Double) -> Int { level(v, [0.05, 2, 10, 30]) }
    static func memory(_ b: UInt64) -> Int { level(Double(b) / Double(1 << 20), [20, 150, 600, 1500]) }
    static func disk(_ bps: Double) -> Int { level(bps / Double(1 << 20), [0.05, 1, 5, 20]) }
    static func network(_ bps: Double) -> Int { level(bps * 8 / 1e6, [0.01, 0.5, 3, 20]) }
    static func power(_ w: Double) -> Int { level(w, [0.05, 0.5, 1.5, 4]) }

    static func color(_ level: Int) -> Color {
        switch level {
        case 0: return .clear
        case 1: return Color(red: 1.0, green: 0.84, blue: 0.25).opacity(0.16)
        case 2: return Color(red: 1.0, green: 0.78, blue: 0.2).opacity(0.30)
        case 3: return Color(red: 1.0, green: 0.62, blue: 0.1).opacity(0.42)
        default: return Color(red: 0.98, green: 0.45, blue: 0.1).opacity(0.55)
        }
    }
}

extension Color {
    static let tmCPU = Color(red: 0.07, green: 0.49, blue: 0.73)
    static let tmMemory = Color(red: 0.55, green: 0.07, blue: 0.68)
    static let tmDisk = Color(red: 0.30, green: 0.65, blue: 0.05)
    static let tmNetwork = Color(red: 0.65, green: 0.35, blue: 0.10)
    static let tmGPU = Color(red: 0.04, green: 0.42, blue: 0.75)
}
