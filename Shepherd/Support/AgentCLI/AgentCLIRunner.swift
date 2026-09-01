import Darwin
import Foundation

/// One live agent run.
///
/// Everything is exposed as `Sendable` values so the delegation model can be tested against a
/// scripted fake without a process anywhere in sight.
struct AgentSession: Sendable {
    /// The decoded events, in order. The stream finishes when the process closes stdout.
    var events: AsyncStream<AgentStreamEvent>
    /// Terminates the run: `SIGTERM`, then `SIGKILL` after a grace period.
    var cancel: @Sendable () -> Void
    /// The exit status. Resolves once the process has been reaped.
    var exitCode: @Sendable () async -> Int32
    /// What was actually spawned, for the transcript header.
    var invocation: AgentInvocation
}

/// Starts agent runs.
protocol AgentRunning: Sendable {
    /// Spawns the agent.
    /// - Parameters:
    ///   - prompt: The complete prompt, Shepherd's preamble included.
    ///   - worktree: The detached worktree to run in; also the process's working directory.
    /// - Returns: The live session.
    /// - Throws: When the invocation cannot be built or the process cannot be spawned.
    func run(prompt: String, in worktree: URL) throws -> AgentSession
}

/// Spawns the configured agent CLI and streams its newline-delimited JSON.
///
/// Three properties matter and are all deliberate:
/// - **The prompt is never interpreted.** No shell is involved anywhere; the prompt is one
///   element of an argv array.
/// - **The environment is inherited verbatim.** Shepherd adds no variable and removes none —
///   in particular it neither injects nor strips `ANTHROPIC_API_KEY`. Whatever authentication
///   the user's CLI has is the authentication the run gets (ADR 0011).
/// - **Reading happens off the main thread.** A dedicated queue drains stdout line by line and
///   feeds an `AsyncStream`; the UI only ever sees decoded events.
struct AgentCLIRunner: AgentRunning {
    /// The guardrails and command shape.
    var configuration: AgentCLIConfiguration
    /// The located binary; `nil` for a custom template, which names its own.
    var executable: URL?
    /// How long a cancelled process gets to exit on `SIGTERM` before `SIGKILL`.
    var terminationGrace: TimeInterval = 5

    /// Creates a runner.
    /// - Parameters:
    ///   - configuration: The guardrails and command shape.
    ///   - executable: The located binary.
    ///   - terminationGrace: Seconds between `SIGTERM` and `SIGKILL`.
    init(
        configuration: AgentCLIConfiguration,
        executable: URL?,
        terminationGrace: TimeInterval = 5
    ) {
        self.configuration = configuration
        self.executable = executable
        self.terminationGrace = terminationGrace
    }

    func run(prompt: String, in worktree: URL) throws -> AgentSession {
        let invocation = try configuration.invocation(
            prompt: prompt,
            worktree: worktree,
            executable: executable
        )

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = worktree
        // No `process.environment = …` line: the child inherits the app's environment as-is.
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let status = AgentExitStatus()
        let processBox = UnsafeSendableBox(process)
        let outputHandle = UnsafeSendableBox(output.fileHandleForReading)
        let errorHandle = UnsafeSendableBox(errors.fileHandleForReading)
        let (stream, continuation) = AsyncStream<AgentStreamEvent>.makeStream()

        // stderr is drained and dropped: a full pipe would block the child, and the CLI's
        // diagnostics belong in its own logs, not in Shepherd's transcript.
        DispatchQueue.global(qos: .utility).async {
            _ = errorHandle.value.readDataToEndOfFile()
        }

        DispatchQueue(label: "com.schnaq.shepherd.agent-cli.reader", qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = outputHandle.value.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    for event in AgentStreamEvent.events(in: line) {
                        continuation.yield(event)
                    }
                }
            }
            // A CLI that exits without a trailing newline still owes us its last line.
            if !buffer.isEmpty {
                for event in AgentStreamEvent.events(in: buffer) {
                    continuation.yield(event)
                }
            }
            processBox.value.waitUntilExit()
            let code = processBox.value.terminationStatus
            Task { await status.complete(code) }
            continuation.finish()
        }

        let grace = terminationGrace
        return AgentSession(
            events: stream,
            cancel: {
                // `Process` is not documented as thread-safe, but termination from another
                // thread is the only way to stop a run: the reader queue is parked in
                // `availableData` until the child closes its pipe.
                let running = processBox.value
                guard running.isRunning else { return }
                running.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                    let stubborn = processBox.value
                    if stubborn.isRunning {
                        kill(stubborn.processIdentifier, SIGKILL)
                    }
                }
            },
            exitCode: { await status.value() },
            invocation: invocation
        )
    }
}

/// A one-shot exit status that late arrivals can still await.
actor AgentExitStatus {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// Creates a pending status.
    init() {}

    /// Records the status and wakes everyone waiting.
    /// - Parameter code: The process's exit status.
    func complete(_ code: Int32) {
        guard status == nil else { return }
        status = code
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: code) }
    }

    /// The exit status, awaiting it if the process is still running.
    func value() async -> Int32 {
        if let status { return status }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
