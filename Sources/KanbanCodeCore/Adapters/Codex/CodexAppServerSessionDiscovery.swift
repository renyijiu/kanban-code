import Foundation

/// App Server-backed discovery for Codex desktop and managed threads. The
/// filesystem discovery remains a content fallback; stable thread identity and
/// runtime provenance come from this adapter when the protocol is available.
public actor CodexAppServerSessionDiscovery: SessionDiscovery {
    private let client: CodexAppServerClient
    private let pageSize: Int
    private let cacheLifetime: TimeInterval
    private var cached: [String: Session] = [:]
    private var lastRefresh: Date?

    public init(
        client: CodexAppServerClient,
        pageSize: Int = 100,
        cacheLifetime: TimeInterval = 30
    ) {
        self.client = client
        self.pageSize = max(1, min(pageSize, 500))
        self.cacheLifetime = max(0, cacheLifetime)
    }

    public func discoverSessions() async throws -> [Session] {
        if let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < cacheLifetime {
            return cached.values.sorted { $0.modifiedTime > $1.modifiedTime }
        }
        var cursor: String?
        var discovered: [String: Session] = [:]
        repeat {
            let page = try await client.listThreads(cursor: cursor, limit: pageSize, archived: false)
            for thread in page.data where thread.archived != true {
                let provenance = Self.provenance(sourceKinds: thread.sourceKinds)
                let existing = cached[thread.id]
                discovered[thread.id] = Session(
                    id: thread.id,
                    name: thread.name,
                    firstPrompt: thread.preview,
                    projectPath: thread.cwd,
                    messageCount: existing?.messageCount ?? 0,
                    modifiedTime: existing?.modifiedTime ?? .now,
                    jsonlPath: existing?.jsonlPath,
                    assistant: .codex,
                    runtimeProvenance: provenance,
                    runtimeLifecycle: Self.lifecycle(status: thread.status)
                )
            }
            cursor = page.nextCursor
        } while cursor != nil
        cached = discovered
        lastRefresh = .now
        return discovered.values.sorted { $0.modifiedTime > $1.modifiedTime }
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        let sessions = try await discoverSessions()
        return sessions.filter { $0.modifiedTime > since }
    }

    public nonisolated static func provenance(sourceKinds: [String]) -> CodexRuntimeProvenance {
        let normalized = sourceKinds.map { $0.lowercased() }
        let hasApp = normalized.contains { value in
            value.contains("app") || value.contains("desktop") || value.contains("vscode")
        }
        let hasCLI = normalized.contains { value in
            value.contains("cli") || value.contains("terminal") || value.contains("exec")
        }
        let backend: CodexRuntimeBackend = if hasApp != hasCLI {
            hasApp ? .app : .cliTmux
        } else {
            .unknown
        }
        return CodexRuntimeProvenance(
            backend: backend,
            ownership: .observed,
            evidence: .appServerSource,
            telemetryQuality: backend == .unknown ? .limited : .precise,
            observedAt: .now
        )
    }

    public nonisolated static func lifecycle(status: CodexThreadStatus?) -> LifecycleSnapshot {
        guard let status else { return .init(phase: .unknown, telemetryQuality: .limited) }
        if status.waitingOnApproval {
            return .init(phase: .waiting, waitReason: .approval, telemetryQuality: .precise)
        }
        if status.waitingOnUserInput {
            return .init(phase: .waiting, waitReason: .input, telemetryQuality: .precise)
        }
        switch status.type.lowercased() {
        case "active", "running", "inprogress":
            return .init(phase: .running, telemetryQuality: .precise)
        default:
            // An old idle thread belongs in All Sessions until a fresh
            // structured event makes it actionable; do not flood attention.
            return .init(phase: .unknown, telemetryQuality: .precise)
        }
    }
}
