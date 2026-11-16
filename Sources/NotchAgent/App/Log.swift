// OWNER: workstream C (app-ui).
import Foundation

/// stderr logging. `NOTCH_AGENT_LOG=1` enables debug lines (island state changes, hotkeys, demo beats).
enum Log {
    static let enabled: Bool = {
        let v = ProcessInfo.processInfo.environment["NOTCH_AGENT_LOG"] ?? ""
        return v == "1" || v.lowercased() == "true"
    }()

    private static let start = Date()

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        write("[notchAgent +\(String(format: "%.2f", max(0, Date().timeIntervalSince(start))))s] \(message())")
    }

    /// Always printed.
    static func info(_ message: String) {
        write("[notchAgent] \(message)")
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
