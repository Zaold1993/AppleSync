import Foundation
import Darwin

public struct ProcessOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data

    public init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
        self.exitCode = exitCode
        self.stdoutData = stdoutData
        self.stderrData = stderrData
    }

    public var stdoutString: String {
        String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var stderrString: String {
        String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ProcessRunnerError: LocalizedError, Sendable, Equatable {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, timeoutSeconds: TimeInterval)
    case nonZeroExit(executable: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason):
            return "Failed to launch '\(executable)': \(reason)"
        case .timedOut(let executable, let timeoutSeconds):
            return "Process '\(executable)' timed out after \(Int(timeoutSeconds))s."
        case .nonZeroExit(let executable, let exitCode, let stderr):
            return "Process '\(executable)' exited with status \(exitCode): \(stderr)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessOutput
}

extension CommandRunning {
    public func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> ProcessOutput {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            timeout: timeout
        )
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class ContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        cont.resume(with: result)
    }
}

public struct SystemProcessRunner: CommandRunning, Sendable {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in environment {
                merged[k] = v
            }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutBuffer.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.append(chunk)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let gate = ContinuationGate(continuation)

                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(max(0.1, timeout)))
                    guard !Task.isCancelled else { return }
                    if process.isRunning {
                        process.terminate()
                    }
                    gate.resume(with: .failure(ProcessRunnerError.timedOut(executable: executable, timeoutSeconds: timeout)))
                }

                process.terminationHandler = { terminatedProcess in
                    timeoutTask.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    if !remainingOut.isEmpty {
                        stdoutBuffer.append(remainingOut)
                    }
                    let remainingErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    if !remainingErr.isEmpty {
                        stderrBuffer.append(remainingErr)
                    }

                    let output = ProcessOutput(
                        exitCode: terminatedProcess.terminationStatus,
                        stdoutData: stdoutBuffer.snapshot(),
                        stderrData: stderrBuffer.snapshot()
                    )
                    gate.resume(with: .success(output))
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    gate.resume(
                        with: .failure(
                            ProcessRunnerError.launchFailed(
                                executable: executable,
                                reason: error.localizedDescription
                            )
                        )
                    )
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

public struct CrossProcessFileLock: Sendable {
    public let lockFileURL: URL

    public init(lockFileURL: URL) {
        self.lockFileURL = lockFileURL
    }

    public func withLock<T: Sendable>(
        timeout: TimeInterval = 30.0,
        retryIntervalNanoseconds: UInt64 = 50_000_000,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let directory = lockFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AppleSyncError.invalidInput("Unable to open lock file at \(lockFileURL.path) (errno \(errno))")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                break
            }
            if errno != EWOULDBLOCK && errno != EAGAIN {
                throw AppleSyncError.invalidInput("flock failed on \(lockFileURL.path) with errno \(errno)")
            }
            if Date() >= deadline {
                throw AppleSyncError.invalidInput("Timed out waiting for exclusive lock on \(lockFileURL.path)")
            }
            try await Task.sleep(nanoseconds: retryIntervalNanoseconds)
        }

        return try await operation()
    }
}
