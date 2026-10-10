import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public func checked() throws -> String {
        guard status == 0 else { throw RippleError(error.isEmpty ? output : error) }
        return output
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func start(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = p
        try p.run()
    }
    func stop(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return }
        cancelled = true
        timedOut = timeout
        guard let p = process, p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var didTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count <= 32 * 1024 * 1024 { data.append(chunk) }
        else { overflow = true }
    }
    func string() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw RippleError("命令输出过大，操作已停止。请打开更小的目录。") }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: Double? = 60,
                           onOutput: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(executable, arguments, timeout: timeout,
                                                                      onOutput: onOutput, control: control))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.stop() })
    }
    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: Double?,
                                    onOutput: (@Sendable (String) -> Void)?, control: ProcessControl) throws -> CommandResult {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "C"
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                let output = Capture(), errors = Capture(), group = DispatchGroup()
                try control.start(process)
                for (pipe, capture) in [(out, output), (err, errors)] {
                    group.enter()
                    DispatchQueue.global().async {
                        defer { group.leave() }
                        while true {
                            let chunk = pipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            capture.append(chunk)
                            onOutput?(String(decoding: chunk, as: UTF8.self))
                        }
                    }
                }
                let timer = DispatchWorkItem { control.stop(timeout: true) }
                if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
                process.waitUntilExit()
                timer.cancel()
                group.wait()
                if control.didTimeout { throw RippleError("操作超时，请检查网络和服务器状态后重试。") }
                if control.wasCancelled { throw CancellationError() }
                return try CommandResult(status: process.terminationStatus, output: output.string(), error: errors.string())
    }
}
