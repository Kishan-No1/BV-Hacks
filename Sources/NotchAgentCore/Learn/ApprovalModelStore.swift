import Foundation

/// The learned approval model on disk: `~/Library/Application Support/notchAgent/approvals.json`. Thread-safe.
/// A missing or corrupt file means an empty model. The feature names include program names, file
/// extensions, hosts and repo folder names, so the file is written with mode 0600 and nothing in here
/// logs them.
public final class ApprovalModelStore: @unchecked Sendable {
    /// `~/Library/Application Support/notchAgent/approvals.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("notchAgent/approvals.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var stored = ApprovalModel.empty

    /// `fileURL: nil` keeps the model in memory only (tests, demo mode, snapshots).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let model = try? JSONDecoder().decode(ApprovalModel.self, from: data) {
            stored = model
        }
    }

    public var model: ApprovalModel {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func predict(toolName: String, toolInput: JSONValue, cwd: String, assessment: Assessment) -> ApprovalPrediction? {
        let features = ApprovalFeatures.extract(toolName: toolName, toolInput: toolInput, cwd: cwd, assessment: assessment)
        lock.lock(); defer { lock.unlock() }
        return stored.predict(features, level: assessment.level)
    }

    public func predict(_ request: PendingRequest) -> ApprovalPrediction? {
        predict(toolName: request.toolName, toolInput: request.toolInput, cwd: request.cwd, assessment: request.assessment)
    }

    /// Learns from one decision the user made and saves.
    public func learn(toolName: String, toolInput: JSONValue, cwd: String, assessment: Assessment, allowed: Bool) {
        let features = ApprovalFeatures.extract(toolName: toolName, toolInput: toolInput, cwd: cwd, assessment: assessment)
        lock.lock(); defer { lock.unlock() }
        stored.learn(features, level: assessment.level, allowed: allowed)
        saveLocked()
    }

    public func learn(_ request: PendingRequest, allowed: Bool) {
        learn(toolName: request.toolName, toolInput: request.toolInput, cwd: request.cwd,
              assessment: request.assessment, allowed: allowed)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        stored = .empty
        saveLocked()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Writes a private temp file next to the target and renames it into place, so a reader never sees half
    /// a file. A failed save keeps the model in memory.
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
