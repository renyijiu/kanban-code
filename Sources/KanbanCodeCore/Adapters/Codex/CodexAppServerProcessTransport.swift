import Foundation

public enum CodexExecutableError: Error, LocalizedError, Sendable, Equatable {
    case notFound
    case notExecutable(String)
    case projectLocalShadow(String)
    case capabilityProbeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Codex executable was not found"
        case .notExecutable(let path): "Codex is not executable: \(path)"
        case .projectLocalShadow(let path): "Refusing project-local Codex executable: \(path)"
        case .capabilityProbeFailed(let details): "Codex App Server capability probe failed: \(details)"
        }
    }
}

public struct CodexExecutableIdentity: Sendable, Equatable {
    public let url: URL
    public let version: String
    public let isStandardLocation: Bool
}

/// Resolves and probes a stable absolute Codex binary. PATH is inspected only
/// during explicit setup; execution always retains the resolved absolute URL.
public enum CodexExecutableResolver {
    public static func resolve(
        configuredPath: String? = nil,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        projectRoot: String? = nil
    ) throws -> CodexExecutableIdentity {
        let candidates = candidateURLs(configuredPath: configuredPath, environmentPath: environmentPath)
        let fileManager = FileManager.default
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path) else { continue }
            guard fileManager.isExecutableFile(atPath: resolved.path) else {
                if configuredPath != nil { throw CodexExecutableError.notExecutable(resolved.path) }
                continue
            }
            if let projectRoot {
                let project = URL(fileURLWithPath: projectRoot, isDirectory: true)
                if isProjectLocal(executable: resolved, projectRoot: project) {
                    throw CodexExecutableError.projectLocalShadow(resolved.path)
                }
            }

            let version = try runProbe(executable: resolved, arguments: ["--version"])
            _ = try runProbe(executable: resolved, arguments: ["app-server", "--help"])
            let standardPrefixes = ["/usr/local/", "/opt/homebrew/", "/Applications/", "/Users/Shared/"]
            return CodexExecutableIdentity(
                url: resolved,
                version: version.trimmingCharacters(in: .whitespacesAndNewlines),
                isStandardLocation: standardPrefixes.contains { resolved.path.hasPrefix($0) }
            )
        }
        throw CodexExecutableError.notFound
    }

    public static func isProjectLocal(executable: URL, projectRoot: URL) -> Bool {
        let executablePath = executable.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return executablePath == rootPath || executablePath.hasPrefix(rootPath + "/")
    }

    private static func candidateURLs(configuredPath: String?, environmentPath: String?) -> [URL] {
        var paths: [String] = []
        if let configuredPath, !configuredPath.isEmpty { paths.append(configuredPath) }
        paths.append(contentsOf: [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
        if let environmentPath {
            paths.append(contentsOf: environmentPath.split(separator: ":").map { "\($0)/codex" })
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let expanded = (path as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return nil }
            return URL(fileURLWithPath: expanded)
        }
    }

    private static func runProbe(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = safeEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexExecutableError.capabilityProbeFailed(error.localizedDescription)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: errorOutput, as: UTF8.self)
            throw CodexExecutableError.capabilityProbeFailed(details.isEmpty ? "exit \(process.terminationStatus)" : details)
        }
        return String(decoding: output.isEmpty ? errorOutput : output, as: UTF8.self)
    }

    fileprivate static func safeEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let allowedKeys = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME"]
        return Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            environment[key].map { (key, $0) }
        })
    }
}

public enum CodexAppServerProcessError: Error, LocalizedError, Sendable {
    case notRunning
    case invalidUTF8
    case lineTooLarge

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Codex App Server process is not running"
        case .invalidUTF8: "Codex App Server emitted invalid UTF-8"
        case .lineTooLarge: "Codex App Server emitted a JSON-RPC line larger than 1 MiB"
        }
    }
}

/// Process-backed line transport. Reads run on a dedicated blocking task so a
/// pending stdout read never prevents JSON-RPC writes from reaching stdin.
public final class CodexAppServerProcessTransport: CodexAppServerLineTransport, @unchecked Sendable {
    private static let maximumLineBytes = 1_048_576
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private var readBuffer = Data()

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    deinit {
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }

    public static func launch(
        executable: URL,
        arguments: [String] = ["app-server"],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> CodexAppServerProcessTransport {
        let runtimeDirectory = workingDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".kanban-code/runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = executable.resolvingSymlinksInPath()
        process.arguments = arguments
        process.currentDirectoryURL = runtimeDirectory
        process.environment = environment ?? CodexExecutableResolver.safeEnvironment()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Keep protocol stdout isolated from diagnostics. A companion can drain
        // and rotate this pipe; the direct development transport discards it.
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        try process.run()
        return CodexAppServerProcessTransport(
            process: process,
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading
        )
    }

    public func writeLine(_ line: String) async throws {
        guard process.isRunning else { throw CodexAppServerProcessError.notRunning }
        guard var data = line.data(using: .utf8) else { throw CodexAppServerProcessError.invalidUTF8 }
        data.append(0x0A)
        try writeLock.withLock {
            try input.write(contentsOf: data)
        }
    }

    public func readLine() async throws -> String? {
        try await Task.detached(priority: .utility) { [self] in
            try readLock.withLock { try readLineBlocking() }
        }.value
    }

    private func readLineBlocking() throws -> String? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                guard let value = String(data: line, encoding: .utf8) else {
                    throw CodexAppServerProcessError.invalidUTF8
                }
                return value
            }
            guard process.isRunning || !readBuffer.isEmpty else { return nil }
            guard let data = try output.read(upToCount: 64 * 1024), !data.isEmpty else {
                if readBuffer.isEmpty { return nil }
                guard let value = String(data: readBuffer, encoding: .utf8) else {
                    throw CodexAppServerProcessError.invalidUTF8
                }
                readBuffer.removeAll(keepingCapacity: false)
                return value
            }
            readBuffer.append(data)
            guard readBuffer.count <= Self.maximumLineBytes else {
                readBuffer.removeAll(keepingCapacity: false)
                throw CodexAppServerProcessError.lineTooLarge
            }
        }
    }
}
