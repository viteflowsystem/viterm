import Foundation

/// Result of running a `git` subprocess.
public struct GitOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

/// Errors related to running a `git` subprocess.
public enum GitError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The git command exited non-zero.
    case commandFailed(arguments: [String], exitCode: Int32, stdout: String, stderr: String)
    /// The command did not finish within the given timeout (the process has been terminated).
    case timedOut(arguments: [String], timeout: TimeInterval)
    /// Launching the process itself failed (executable not found, etc.).
    case launchFailed(arguments: [String], reason: String)

    public var description: String {
        switch self {
        case let .commandFailed(arguments, exitCode, stdout, stderr):
            let detail = Self.firstNonEmpty(stderr, stdout)
            return "git \(arguments.joined(separator: " ")) failed (exit code \(exitCode)): \(detail)"
        case let .timedOut(arguments, timeout):
            return "git \(arguments.joined(separator: " ")) timed out after \(timeout)s"
        case let .launchFailed(arguments, reason):
            return "failed to launch git \(arguments.joined(separator: " ")): \(reason)"
        }
    }

    /// The stderr attached to a failed command (stdout if empty). Used to extract a short message for UI display.
    public var diagnosticMessage: String {
        switch self {
        case let .commandFailed(_, _, stdout, stderr):
            return Self.firstNonEmpty(stderr, stdout)
        case .timedOut, .launchFailed:
            return description
        }
    }

    private static func firstNonEmpty(_ primary: String, _ fallback: String) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty { return trimmedPrimary }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thin wrapper that runs `git` via `Foundation.Process`. async/await based;
/// responsible for timeouts, capturing stdout/stderr, and turning non-zero exits into errors.
///
/// GitService builds git-specific operations (worktree / branch / merge, etc.) on top of this.
public struct GitRunner: Sendable {
    /// The program to execute. Defaults to `/usr/bin/env`, in which case `git` is prepended
    /// as the first argument (to delegate PATH resolution to the OS). Tests can point this
    /// directly at a fake executable.
    public var executableURL: URL
    /// Timeout in seconds used when `run` / `runRaw` is called without an explicit timeout.
    public var defaultTimeout: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        defaultTimeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.defaultTimeout = defaultTimeout
    }

    /// Run git and return stdout as a string. Throws `GitError.commandFailed` on non-zero exit.
    @discardableResult
    public func run(_ arguments: [String], in directory: URL, timeout: TimeInterval? = nil) async throws -> String {
        try await runRaw(arguments, in: directory, timeout: timeout).stdout
    }

    /// Run git and return stdout/stderr/exit code together.
    public func runRaw(_ arguments: [String], in directory: URL, timeout: TimeInterval? = nil) async throws -> GitOutput {
        let effectiveTimeout = timeout ?? defaultTimeout

        let process = Process()
        process.executableURL = executableURL
        process.arguments = launchArguments(for: arguments)
        process.currentDirectoryURL = directory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(arguments: arguments, reason: error.localizedDescription)
        }

        async let stdoutData = Self.readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readAll(stderrPipe.fileHandleForReading)

        // `withTaskGroup` waits for all child tasks to finish before the closure returns, so
        // when the timeout side fires first, `process.terminate()` must be called right there.
        // Otherwise the waitForExit task, blocked on its completion handler, would not finish
        // until the real process exits, making the timeout exist in name only (i.e. calling
        // terminate() at the call site would be too late).
        let didTimeOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Self.waitForExit(process)
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(effectiveTimeout, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return true }
                if process.isRunning {
                    process.terminate()
                }
                return true
            }
            let timedOut = await group.next() ?? false
            group.cancelAll()
            return timedOut
        }

        let terminationStatus = process.terminationStatus
        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""

        if didTimeOut {
            throw GitError.timedOut(arguments: arguments, timeout: effectiveTimeout)
        }

        guard terminationStatus == 0 else {
            throw GitError.commandFailed(
                arguments: arguments,
                exitCode: terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }

        return GitOutput(stdout: stdout, stderr: stderr, exitCode: terminationStatus)
    }

    private func launchArguments(for arguments: [String]) -> [String] {
        guard executableURL.lastPathComponent == "env" else { return arguments }
        return ["git"] + arguments
    }

    /// Read the pipe until EOF (write side closed). Called concurrently with waiting for
    /// process exit so large outputs don't deadlock on a full pipe buffer.
    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    private static func waitForExit(_ process: Process) async -> Void {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }
}
