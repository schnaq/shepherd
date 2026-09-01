import Foundation

/// What one finished subprocess reported.
struct ProcessResult: Sendable, Equatable {
    /// The exit status; `0` is success.
    var status: Int32
    /// Everything the process wrote to stdout.
    var standardOutput: String
    /// Everything the process wrote to stderr.
    var standardError: String

    /// Whether the process exited cleanly.
    var isSuccess: Bool { status == 0 }

    /// stdout with surrounding whitespace removed — what almost every git call wants.
    var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a subprocess to completion and hands back what it printed.
///
/// This is the seam the delegation engine is tested against: `GitWorktree` never touches
/// `Process` directly, so the unit tests can assert the **exact argv** of every git command
/// without a repository on disk.
protocol ProcessRunning: Sendable {
    /// Runs a command and waits for it.
    /// - Parameters:
    ///   - executable: The binary to exec.
    ///   - arguments: argv, without argv[0].
    ///   - currentDirectory: The working directory, or `nil` to inherit.
    /// - Returns: Exit status and captured output.
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) async throws -> ProcessResult
}

/// A holder that carries a non-`Sendable` value across a dispatch boundary.
///
/// Every use in this folder confines the boxed value to a single queue (or serialises access
/// with a `DispatchGroup`), which is what makes the `@unchecked` honest.
final class UnsafeSendableBox<Value>: @unchecked Sendable {
    /// The boxed value.
    var value: Value

    /// Boxes a value.
    /// - Parameter value: The value to carry.
    init(_ value: Value) {
        self.value = value
    }
}

/// The real `Process`-backed runner.
struct SystemProcessRunner: ProcessRunning {
    /// A shared instance; the type is stateless.
    static let shared = SystemProcessRunner()

    private static let queue = DispatchQueue(
        label: "com.schnaq.shepherd.process",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Creates a runner.
    init() {}

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    if let currentDirectory {
                        process.currentDirectoryURL = currentDirectory
                    }
                    let output = Pipe()
                    let errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    // Nothing may prompt: a child that reads stdin would hang forever behind a
                    // window the user cannot see.
                    process.standardInput = FileHandle.nullDevice
                    try process.run()

                    // Both pipes are drained at the same time. Reading one to EOF while the
                    // other fills its 64 KiB buffer is a classic deadlock — `git fetch` writes
                    // plenty of progress to stderr.
                    let group = DispatchGroup()
                    let errorHandle = UnsafeSendableBox(errors.fileHandleForReading)
                    let errorData = UnsafeSendableBox(Data())
                    Self.queue.async(group: group) {
                        errorData.value = errorHandle.value.readDataToEndOfFile()
                    }
                    let outputData = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()

                    continuation.resume(
                        returning: ProcessResult(
                            status: process.terminationStatus,
                            standardOutput: String(decoding: outputData, as: UTF8.self),
                            standardError: String(decoding: errorData.value, as: UTF8.self)
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
