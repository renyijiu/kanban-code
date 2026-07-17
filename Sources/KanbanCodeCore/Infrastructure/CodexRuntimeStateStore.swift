import Foundation

/// Atomic, actor-isolated persistence for per-card Codex lifecycle and launch state.
public actor CodexRuntimeStateStore {
    private struct Container: Codable {
        var version: Int
        var states: [String: CardRuntimeState]

        init(version: Int = 1, states: [String: CardRuntimeState] = [:]) {
            self.version = version
            self.states = states
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        fileURL = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("codex-runtime-state.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func readAll() throws -> [String: CardRuntimeState] {
        try readContainer().states
    }

    public func state(for cardId: String) throws -> CardRuntimeState? {
        try readContainer().states[cardId]
    }

    public func upsert(_ state: CardRuntimeState) throws {
        var container = try readContainer()
        container.states[state.cardId] = state
        try write(container)
    }

    /// Reduces and persists a lifecycle event in one actor-isolated operation.
    /// This prevents an App Server event and a hook event from both reducing
    /// against the same stale snapshot across suspension points.
    @discardableResult
    public func applyLifecycleEvent(_ event: CodexLifecycleEvent) throws -> CodexLifecycleReduction {
        var container = try readContainer()
        let reduction = CodexLifecycleReducer.reduce(
            current: container.states[event.cardId],
            event: event
        )
        switch reduction {
        case .applied(let state), .conflicted(let state):
            container.states[event.cardId] = state
            try write(container)
        case .duplicate, .ignoredStale:
            break
        }
        return reduction
    }

    public func remove(cardId: String) throws {
        var container = try readContainer()
        guard container.states.removeValue(forKey: cardId) != nil else { return }
        try write(container)
    }

    public func rekey(sourceCardId: String, targetCardId: String) throws {
        var container = try readContainer()
        guard var source = container.states[sourceCardId] else { return }
        if let target = container.states[targetCardId], target != source {
            throw CodexRuntimeStateStoreError.conflictingTarget(targetCardId)
        }
        source.cardId = targetCardId
        container.states[targetCardId] = source
        container.states.removeValue(forKey: sourceCardId)
        try write(container)
    }

    private func readContainer() throws -> Container {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Container() }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode(Container.self, from: data)
        } catch {
            let backupURL = fileURL.appendingPathExtension("bkp")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            throw CodexRuntimeStateStoreError.corrupt(fileURL.path)
        }
    }

    private func write(_ container: Container) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try encoder.encode(container).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum CodexRuntimeStateStoreError: Error, LocalizedError {
    case conflictingTarget(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingTarget(let cardId):
            "Codex runtime state already exists for target card \(cardId)"
        case .corrupt(let path):
            "Codex runtime state is corrupt at \(path)"
        }
    }
}
