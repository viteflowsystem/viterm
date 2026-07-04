import Foundation

/// `git` サブプロセスの実行結果。
public struct GitOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

/// `git` サブプロセスの実行に関するエラー。
public enum GitError: Error, CustomStringConvertible, Sendable, Equatable {
    /// git コマンドが非0で終了した。
    case commandFailed(arguments: [String], exitCode: Int32, stdout: String, stderr: String)
    /// 指定タイムアウト内にコマンドが完了しなかった(プロセスは terminate 済み)。
    case timedOut(arguments: [String], timeout: TimeInterval)
    /// プロセス自体の起動に失敗した(実行ファイルが見つからない等)。
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

    /// コマンド失敗時に添付された stderr(空なら stdout)。UI 表示用の短いメッセージ抽出に使う。
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

/// `Foundation.Process` で `git` を実行する薄いラッパー。async/await ベースで、
/// タイムアウト・stdout/stderr の取得・非0終了時のエラー化を担う。
///
/// GitService はこの上に git 固有の操作(worktree / branch / merge 等)を構築する。
public struct GitRunner: Sendable {
    /// 実行するプログラム。既定は `/usr/bin/env` で、その場合 `git` を第一引数として補う
    /// (PATH 解決を OS に委ねるため)。テストではフェイクの実行ファイルを直接指すこともできる。
    public var executableURL: URL
    /// `run` / `runRaw` に timeout を明示しなかった場合に使うタイムアウト秒数。
    public var defaultTimeout: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        defaultTimeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.defaultTimeout = defaultTimeout
    }

    /// git を実行し、stdout の文字列を返す。非0終了時は `GitError.commandFailed` を投げる。
    @discardableResult
    public func run(_ arguments: [String], in directory: URL, timeout: TimeInterval? = nil) async throws -> String {
        try await runRaw(arguments, in: directory, timeout: timeout).stdout
    }

    /// git を実行し、stdout/stderr/終了コードをまとめて返す。
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

        // `withTaskGroup` はクロージャが戻る前に全子タスクの完了を待つため、タイムアウト側が先に
        // 発火した場合は「その場で」`process.terminate()` を呼ぶ必要がある。そうしないと、
        // completion handler 待ちの waitForExit タスクが実プロセス終了まで完了せず、
        // 結果的にタイムアウトが名ばかりになってしまう(=呼び出し元での terminate() は手遅れ)。
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

    /// パイプが EOF(書き込み側クローズ)になるまで読み切る。大きい出力でもパイプバッファ詰まりで
    /// デッドロックしないよう、プロセス終了を待つのと並行して呼び出す。
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
