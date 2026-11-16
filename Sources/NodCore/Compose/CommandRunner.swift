// Shared by the repo-context gatherer (git) and the tmux sender. Never logs arguments or stdin.
import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Runs a local program with an explicit argument vector (never through a shell).
public protocol CommandRunning: Sendable {
    /// Returns nil when the program could not be started or did not finish within `timeout`.
    func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) -> CommandResult?
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) -> CommandResult? {
        run(executable, arguments, stdin: nil, timeout: timeout)
    }
}

/// `Process`-backed runner. Output is read on background queues so a chatty child can never fill a pipe
/// and deadlock; a child that outlives `timeout` is terminated.
public struct ProcessCommandRunner: CommandRunning {
    /// Extra environment on top of the inherited one (for example `GIT_OPTIONAL_LOCKS=0`).
    public var environment: [String: String]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = input ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        let box = OutputBox()
        let readers = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: readers) { box.setOut(out.fileHandleForReading.readDataToEndOfFile()) }
        queue.async(group: readers) { box.setErr(err.fileHandleForReading.readDataToEndOfFile()) }
        if let input, let stdin {
            queue.async {
                // A child that exits early closes the pipe; ignore the resulting write error.
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }

        if exited.wait(timeout: .now() + max(0.05, timeout)) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        _ = readers.wait(timeout: .now() + 2)
        let (o, e) = box.get()
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    func get() -> (Data, Data) {
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}
