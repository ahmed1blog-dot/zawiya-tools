import Foundation
import Darwin

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public func check() throws { if isCancelled { throw EngineError.cancelled } }
}

public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], in directory: URL, cancellation: Cancellation, timeout: TimeInterval = 1200, workingDirectory: URL? = nil) throws {
        try cancellation.check()
        let log = directory.appendingPathComponent("process-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory ?? directory
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if cancellation.isCancelled || Date() > deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.03) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.isCancelled { throw EngineError.cancelled }
                throw EngineError.failed("انتهت مهلة المعالجة / Processing timed out.")
            }
            // Drain to disk instead of a pipe, with a bounded log size.
            if ((try? handle.offset()) ?? 0) > 2_000_000 { try? handle.truncate(atOffset: 0); try? handle.seek(toOffset: 0) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: log)) ?? Data()
            let tail = String(decoding: data.suffix(3000), as: UTF8.self)
            throw EngineError.failed("\(executable.lastPathComponent): \(tail)")
        }
    }
}
