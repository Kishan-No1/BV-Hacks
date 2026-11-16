import Foundation

/// The learned style profile on disk: `~/Library/Application Support/notchAgent/style.json`. Thread-safe.
/// A missing or corrupt file means an empty profile. The file holds the user's prompts, so it is written
/// with mode 0600 and nothing in here logs its contents.
public final class StyleProfileStore: @unchecked Sendable {
    /// `~/Library/Application Support/notchAgent/style.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("notchAgent/style.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var stored = StyleProfile.empty

    /// `fileURL: nil` keeps the profile in memory only (tests, snapshots).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let profile = try? Self.decoder.decode(StyleProfile.self, from: data) {
            stored = profile
        }
    }

    public var profile: StyleProfile {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Learns from the outcome, saves, and returns what changed.
    @discardableResult
    public func record(_ outcome: StyleOutcome) -> [StyleChange] {
        lock.lock(); defer { lock.unlock() }
        let result = StyleLearner.learn(stored, outcome: outcome)
        stored = result.profile
        saveLocked()
        return result.changes
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        stored = .empty
        saveLocked()
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Writes a private temp file next to the target and renames it into place, so a reader never sees half
    /// a file and the profile is never readable by other users. A failed save keeps the profile in memory.
    private func saveLocked() {
        guard let fileURL, let data = try? Self.encoder.encode(stored) else { return }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }
        let temp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, fileURL.path) != 0 {
            try? fm.removeItem(at: temp)
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
