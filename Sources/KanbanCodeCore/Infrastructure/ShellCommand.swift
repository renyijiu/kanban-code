import Foundation

/// Runs shell commands and returns their output.
public enum ShellCommand {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }
    }

    /// Cached user login-shell environment, resolved once on first use.
    /// .app bundles get a minimal environment (TMPDIR=/var/folders/..., PATH=/usr/bin:/bin)
    /// which causes tmux socket mismatches, missing binaries, etc. We resolve the real
    /// environment from the user's login shell and inject it into every subprocess.
    private static let userEnvironment: [String: String] = {
        // Run the user's login shell to dump its environment
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "env"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return ProcessInfo.processInfo.environment
            }
            var env: [String: String] = [:]
            for line in output.components(separatedBy: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                let value = String(line[line.index(after: eq)...])
                env[key] = value
            }
            return env.isEmpty ? ProcessInfo.processInfo.environment : env
        } catch {
            return ProcessInfo.processInfo.environment
        }
    }()

    /// Background queue for blocking process I/O — never touches the main thread.
    private static let processQueue = DispatchQueue(label: "kanban.shell", qos: .userInitiated, attributes: .concurrent)

    /// Run a command and capture its output. All blocking I/O runs on a background
    /// dispatch queue so the Swift cooperative thread pool (and main thread) stays free.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        stdin: String? = nil
    ) async throws -> Result {
        let env = userEnvironment
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = env

                if let dir = currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let stdin, let data = stdin.data(using: .utf8) {
                    let stdinPipe = Pipe()
                    process.standardInput = stdinPipe
                    stdinPipe.fileHandleForWriting.write(data)
                    stdinPipe.fileHandleForWriting.closeFile()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read pipe data BEFORE waitUntilExit to avoid deadlock when output
                // exceeds the pipe buffer (~64KB).
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                let result = Result(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Check if a command is available on the system.
    public static func isAvailable(_ command: String) async -> Bool {
        findExecutable(command) != nil
    }

    /// Resolve a command name to an absolute path by checking common locations
    /// plus the user's login-shell PATH (which includes nvm, volta, fnm, etc.).
    /// macOS .app bundles have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so Homebrew and other tools aren't found via `env` or `which`.
    /// Returns nil if the command isn't found anywhere.
    public static func findExecutable(_ command: String) -> String? {
        let home = NSHomeDirectory()
        var searchPaths = [
            "\(home)/.claude/local",   // Claude Code managed install
            "\(home)/.local/bin",      // XDG local bin / claude installer
            "/opt/homebrew/bin",       // Homebrew (Apple Silicon)
            "/usr/local/bin",          // Homebrew (Intel) / npm global
            "/usr/bin",                // System binaries
            "/bin",                    // Core system binaries
        ]

        // Also search the user's real PATH (resolved from login shell).
        // This picks up nvm, volta, fnm, and other version-managed installs.
        if let userPath = userEnvironment["PATH"] {
            for dir in userPath.components(separatedBy: ":") where !dir.isEmpty {
                if !searchPaths.contains(dir) {
                    searchPaths.append(dir)
                }
            }
        }

        for dir in searchPaths {
            let path = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// POSIX-shell single-quote escaping used by launch command builders.
    public static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
