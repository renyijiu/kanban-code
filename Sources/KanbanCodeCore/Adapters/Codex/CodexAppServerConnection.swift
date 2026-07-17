import Foundation

/// One app-wide App Server process shared by discovery and managed launches.
/// The process transport is retained by the client for the app lifetime.
public actor CodexAppServerConnection {
    public typealias ClientFactory = @Sendable () async throws -> CodexAppServerClient

    public static let shared = CodexAppServerConnection()

    private var connectedClient: CodexAppServerClient?
    private var connectingTask: Task<CodexAppServerClient, Error>?
    private let makeClient: ClientFactory

    public init() {
        self.makeClient = CodexAppServerConnection.launchClient
    }

    public init(makeClient: @escaping ClientFactory) {
        self.makeClient = makeClient
    }

    public func client() async throws -> CodexAppServerClient {
        if let connectedClient, await connectedClient.isConnected { return connectedClient }
        if let connectingTask { return try await connectingTask.value }
        if let connectedClient { await connectedClient.disconnect() }
        self.connectedClient = nil

        let task = Task { try await makeClient() }
        connectingTask = task
        do {
            let client = try await task.value
            connectedClient = client
            connectingTask = nil
            return client
        } catch {
            connectingTask = nil
            throw error
        }
    }

    private static func launchClient() async throws -> CodexAppServerClient {
        let identity = try CodexExecutableResolver.resolve()
        let daemonStart = try? await ShellCommand.run(
            identity.url.path,
            arguments: ["app-server", "daemon", "start"]
        )
        let processArguments = daemonStart?.succeeded == true
            ? ["app-server", "proxy"]
            : ["app-server"]
        let transport = try CodexAppServerProcessTransport.launch(
            executable: identity.url,
            arguments: processArguments
        )
        let client = CodexAppServerClient(transport: transport)
        await client.start()
        _ = try await client.initialize(clientName: "kanban-code", clientVersion: "0.1.1")
        return client
    }
}

/// Merges local rollout metadata with App Server identity/provenance. Local
/// discovery remains available when the installed Codex protocol is absent.
public actor CodexHybridSessionDiscovery: SessionDiscovery {
    private let local: CodexSessionDiscovery
    private let connection: CodexAppServerConnection
    private var appServer: CodexAppServerSessionDiscovery?

    public init(
        local: CodexSessionDiscovery = CodexSessionDiscovery(),
        connection: CodexAppServerConnection = .shared
    ) {
        self.local = local
        self.connection = connection
    }

    public func discoverSessions() async throws -> [Session] {
        let localSessions = try await local.discoverSessions()
        do {
            let discovery: CodexAppServerSessionDiscovery
            if let appServer {
                discovery = appServer
            } else {
                discovery = CodexAppServerSessionDiscovery(client: try await connection.client())
                appServer = discovery
            }
            let appSessions = try await discovery.discoverSessions()
            var merged = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.id, $0) })
            for appSession in appSessions {
                if let localSession = merged[appSession.id] {
                    var enriched = appSession
                    enriched.jsonlPath = localSession.jsonlPath
                    enriched.messageCount = localSession.messageCount
                    enriched.modifiedTime = localSession.modifiedTime
                    enriched.firstPrompt = appSession.firstPrompt ?? localSession.firstPrompt
                    enriched.projectPath = appSession.projectPath ?? localSession.projectPath
                    merged[appSession.id] = enriched
                } else {
                    merged[appSession.id] = appSession
                }
            }
            return merged.values.sorted { $0.modifiedTime > $1.modifiedTime }
        } catch {
            return localSessions
        }
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        try await discoverSessions().filter { $0.modifiedTime > since }
    }
}
