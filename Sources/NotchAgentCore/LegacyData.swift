import Foundation

/// notchAgent was called Nod until 2026-11-15. The first time the renamed app runs, the old data folder
/// (rules, learned approvals, learned style, pane records) moves to the new name so nothing is lost.
public enum LegacyData {
    public static let legacyFolderName = "Nod"
    public static let folderName = "notchAgent"

    /// Moves `<base>/Nod` to `<base>/notchAgent` when only the old folder exists. Returns true when it moved.
    /// Never merges or overwrites: if the new folder already exists, both are left as they are.
    @discardableResult
    public static func migrate(base: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                               fileManager: FileManager = .default) -> Bool {
        guard let base else { return false }
        let old = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = base.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue,
              !fileManager.fileExists(atPath: new.path) else { return false }
        do {
            try fileManager.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }
}
