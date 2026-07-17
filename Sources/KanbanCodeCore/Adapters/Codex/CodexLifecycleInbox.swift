import Foundation
import Security

/// Versioned, non-authorizing lifecycle signals emitted by Codex hooks and the
/// bundled review-ready helper. Payload text is never interpreted or executed.
public struct CodexLifecycleEnvelope: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let cardId: String
    public let sessionId: String
    public let attemptId: String
    public let generation: Int
    public let kind: CodexLifecycleEventKind
    public let backend: CodexRuntimeBackend
    public let turnId: String?
    public let sequence: Int?
    public let occurredAt: Date
    public let capability: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String = UUID().uuidString,
        cardId: String,
        sessionId: String,
        attemptId: String,
        generation: Int,
        kind: CodexLifecycleEventKind,
        backend: CodexRuntimeBackend,
        turnId: String? = nil,
        sequence: Int? = nil,
        occurredAt: Date = .now,
        capability: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.cardId = cardId
        self.sessionId = sessionId
        self.attemptId = attemptId
        self.generation = generation
        self.kind = kind
        self.backend = backend
        self.turnId = turnId
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.capability = capability
    }
}

/// The exact launch attempt an inbox event is allowed to affect.
public struct CodexLifecycleExpectedBinding: Sendable, Equatable {
    public let cardId: String
    public let sessionId: String
    public let attemptId: String
    public let generation: Int
    public let backend: CodexRuntimeBackend
    public let capability: String

    public init(
        cardId: String,
        sessionId: String,
        attemptId: String,
        generation: Int,
        backend: CodexRuntimeBackend,
        capability: String
    ) {
        self.cardId = cardId
        self.sessionId = sessionId
        self.attemptId = attemptId
        self.generation = generation
        self.backend = backend
        self.capability = capability
    }
}

public enum CodexLifecycleInboxError: LocalizedError, Equatable {
    case eventTooLarge(actual: Int, maximum: Int)
    case invalidEnvelope(String)
    case randomGenerationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .eventTooLarge(let actual, let maximum):
            "Lifecycle event is \(actual) bytes; maximum is \(maximum) bytes"
        case .invalidEnvelope(let reason):
            "Invalid lifecycle event: \(reason)"
        case .randomGenerationFailed(let status):
            "Could not generate lifecycle capability (status \(status))"
        }
    }
}

public enum CodexLifecycleInboxDiagnosticReason: String, Sendable, Equatable {
    case malformed
    case tooLarge
    case unsupportedSchema
    case duplicate
    case missingBinding
    case bindingMismatch
    case invalidCapability
}

public struct CodexLifecycleInboxDiagnostic: Sendable, Equatable {
    public let fileName: String
    public let eventId: String?
    public let reason: CodexLifecycleInboxDiagnosticReason

    public init(fileName: String, eventId: String?, reason: CodexLifecycleInboxDiagnosticReason) {
        self.fileName = fileName
        self.eventId = eventId
        self.reason = reason
    }
}

public struct CodexLifecycleInboxBatch: Sendable, Equatable {
    public let events: [CodexLifecycleEvent]
    public let diagnostics: [CodexLifecycleInboxDiagnostic]
    public let acknowledgements: [CodexLifecycleInboxAcknowledgement]

    public init(
        events: [CodexLifecycleEvent],
        diagnostics: [CodexLifecycleInboxDiagnostic],
        acknowledgements: [CodexLifecycleInboxAcknowledgement] = []
    ) {
        self.events = events
        self.diagnostics = diagnostics
        self.acknowledgements = acknowledgements
    }
}

public struct CodexLifecycleInboxAcknowledgement: Sendable, Equatable {
    public let fileName: String
    public let eventId: String?
}

public struct CodexLifecycleAppendResult: Sendable, Equatable {
    public let fileName: String
    public let rotatedEventCount: Int
}

public enum CodexLifecycleCapability {
    /// Generates a per-attempt 256-bit capability. It must remain in the
    /// Swift-owned launch lease and the child process environment only.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CodexLifecycleInboxError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ capability: String) -> Bool {
        capability.utf8.count == 64 && capability.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Avoids an early-return timing signal for equal-length capabilities.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }
}

/// Atomic, bounded writer shared by the helper executable and app adapters.
/// Each event is its own file so concurrent helper processes never interleave
/// JSON bytes as they could with a shared JSONL append.
public actor CodexLifecycleInboxWriter {
    public static let maximumEventBytes = 1_048_576
    public static let maximumQueuedEvents = 10_000

    private let pendingDirectory: URL
    private let maximumEventBytes: Int
    private let maximumQueuedEvents: Int
    private let fileManager: FileManager

    public init(
        basePath: String? = nil,
        maximumEventBytes: Int = CodexLifecycleInboxWriter.maximumEventBytes,
        maximumQueuedEvents: Int = CodexLifecycleInboxWriter.maximumQueuedEvents,
        fileManager: FileManager = .default
    ) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.pendingDirectory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("codex-lifecycle-inbox", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        self.maximumEventBytes = min(max(1, maximumEventBytes), Self.maximumEventBytes)
        self.maximumQueuedEvents = min(max(1, maximumQueuedEvents), Self.maximumQueuedEvents)
        self.fileManager = fileManager
    }

    @discardableResult
    public func append(_ envelope: CodexLifecycleEnvelope) throws -> CodexLifecycleAppendResult {
        try Self.validate(envelope)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumEventBytes else {
            throw CodexLifecycleInboxError.eventTooLarge(actual: data.count, maximum: maximumEventBytes)
        }

        try prepareDirectory()
        let fileName = Self.makeFileName(eventId: envelope.id)
        let destination = pendingDirectory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let rotated = try rotateIfNeeded()
        return CodexLifecycleAppendResult(fileName: fileName, rotatedEventCount: rotated)
    }

    private func prepareDirectory() throws {
        let inbox = pendingDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingDirectory.path)
    }

    private func rotateIfNeeded() throws -> Int {
        var files = try eventFiles()
        guard files.count > maximumQueuedEvents else { return 0 }
        let removeCount = files.count - maximumQueuedEvents
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.prefix(removeCount) {
            try fileManager.removeItem(at: file)
        }
        return removeCount
    }

    private func eventFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: pendingDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private static func makeFileName(eventId: String) -> String {
        let nanos = DispatchTime.now().uptimeNanoseconds
        let safeId = eventId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(format: "%020llu-%@-%@.json", nanos, safeId.prefix(80).description, UUID().uuidString)
    }

    fileprivate static func validate(_ envelope: CodexLifecycleEnvelope) throws {
        guard envelope.schemaVersion == CodexLifecycleEnvelope.currentSchemaVersion else {
            throw CodexLifecycleInboxError.invalidEnvelope("unsupported schema version")
        }
        guard !envelope.id.isEmpty, envelope.id.utf8.count <= 256 else {
            throw CodexLifecycleInboxError.invalidEnvelope("event id is missing or too long")
        }
        for (name, value) in [
            ("card id", envelope.cardId),
            ("session id", envelope.sessionId),
            ("attempt id", envelope.attemptId),
        ] {
            guard !value.isEmpty, value.utf8.count <= 512 else {
                throw CodexLifecycleInboxError.invalidEnvelope("\(name) is missing or too long")
            }
        }
        guard envelope.generation >= 0 else {
            throw CodexLifecycleInboxError.invalidEnvelope("generation is negative")
        }
        guard envelope.backend != .unknown else {
            throw CodexLifecycleInboxError.invalidEnvelope("runtime backend is unknown")
        }
        guard CodexLifecycleCapability.isValid(envelope.capability) else {
            throw CodexLifecycleInboxError.invalidEnvelope("capability is not 256-bit lowercase hex")
        }
    }
}

/// Drains inbox files with persistent replay protection. Draining is a read
/// phase; callers acknowledge only after the projected state is durable, then
/// the cursor is committed and processed files are removed.
public actor CodexLifecycleInboxReader {
    private struct Cursor: Codable {
        var seenEventIds: [String] = []
    }

    private let inboxDirectory: URL
    private let pendingDirectory: URL
    private let cursorURL: URL
    private let maximumEventBytes: Int
    private let maximumSeenEventIds: Int
    private let fileManager: FileManager

    public init(
        basePath: String? = nil,
        maximumEventBytes: Int = CodexLifecycleInboxWriter.maximumEventBytes,
        maximumSeenEventIds: Int = CodexLifecycleInboxWriter.maximumQueuedEvents,
        fileManager: FileManager = .default
    ) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.inboxDirectory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("codex-lifecycle-inbox", isDirectory: true)
        self.pendingDirectory = inboxDirectory.appendingPathComponent("pending", isDirectory: true)
        self.cursorURL = inboxDirectory.appendingPathComponent("cursor.json", isDirectory: false)
        self.maximumEventBytes = min(max(1, maximumEventBytes), CodexLifecycleInboxWriter.maximumEventBytes)
        self.maximumSeenEventIds = min(max(1, maximumSeenEventIds), CodexLifecycleInboxWriter.maximumQueuedEvents)
        self.fileManager = fileManager
    }

    public func hasPendingEvents() -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return files.contains { $0.pathExtension == "json" }
    }

    public func drain(bindings: [String: CodexLifecycleExpectedBinding]) throws -> CodexLifecycleInboxBatch {
        guard fileManager.fileExists(atPath: pendingDirectory.path) else {
            return CodexLifecycleInboxBatch(events: [], diagnostics: [], acknowledgements: [])
        }

        let files = try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            return CodexLifecycleInboxBatch(events: [], diagnostics: [], acknowledgements: [])
        }

        let cursor = try loadCursor()
        var seen = Set(cursor.seenEventIds)
        var events: [CodexLifecycleEvent] = []
        var diagnostics: [CodexLifecycleInboxDiagnostic] = []
        var acknowledgements: [CodexLifecycleInboxAcknowledgement] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files.prefix(CodexLifecycleInboxWriter.maximumQueuedEvents) {
            acknowledgements.append(.init(fileName: file.lastPathComponent, eventId: nil))
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values?.fileSize, size <= maximumEventBytes else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: nil, reason: .tooLarge))
                continue
            }
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  let envelope = try? decoder.decode(CodexLifecycleEnvelope.self, from: data) else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: nil, reason: .malformed))
                continue
            }
            acknowledgements[acknowledgements.count - 1] = .init(
                fileName: file.lastPathComponent,
                eventId: envelope.id
            )
            guard envelope.schemaVersion == CodexLifecycleEnvelope.currentSchemaVersion else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: envelope.id, reason: .unsupportedSchema))
                _ = seen.insert(envelope.id)
                continue
            }
            guard !seen.contains(envelope.id) else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: envelope.id, reason: .duplicate))
                continue
            }
            _ = seen.insert(envelope.id)

            guard let binding = bindings[envelope.cardId] else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: envelope.id, reason: .missingBinding))
                continue
            }
            guard binding.cardId == envelope.cardId,
                  binding.sessionId == envelope.sessionId,
                  binding.attemptId == envelope.attemptId,
                  binding.generation == envelope.generation,
                  binding.backend == envelope.backend else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: envelope.id, reason: .bindingMismatch))
                continue
            }
            guard CodexLifecycleCapability.isValid(envelope.capability),
                  CodexLifecycleCapability.constantTimeEquals(binding.capability, envelope.capability) else {
                diagnostics.append(.init(fileName: file.lastPathComponent, eventId: envelope.id, reason: .invalidCapability))
                continue
            }

            events.append(CodexLifecycleEvent(
                id: envelope.id,
                cardId: envelope.cardId,
                kind: envelope.kind,
                watermark: LifecycleEventWatermark(
                    eventId: envelope.id,
                    source: "codex-lifecycle-inbox",
                    generation: envelope.generation,
                    turnId: envelope.turnId,
                    sequence: envelope.sequence,
                    occurredAt: envelope.occurredAt
                ),
                telemetryQuality: .precise
            ))
        }

        return CodexLifecycleInboxBatch(
            events: events,
            diagnostics: diagnostics,
            acknowledgements: acknowledgements
        )
    }

    /// Commits replay protection only after the caller has durably applied all
    /// validated lifecycle events in the batch.
    public func acknowledge(_ batch: CodexLifecycleInboxBatch) throws {
        var cursor = try loadCursor()
        var seen = Set(cursor.seenEventIds)
        for acknowledgement in batch.acknowledgements {
            if let eventId = acknowledgement.eventId {
                record(eventId, cursor: &cursor, seen: &seen)
            }
        }
        if cursor.seenEventIds.count > maximumSeenEventIds {
            cursor.seenEventIds.removeFirst(cursor.seenEventIds.count - maximumSeenEventIds)
        }
        try saveCursor(cursor)
        for acknowledgement in batch.acknowledgements {
            let fileName = URL(fileURLWithPath: acknowledgement.fileName).lastPathComponent
            try? fileManager.removeItem(at: pendingDirectory.appendingPathComponent(fileName))
        }
    }

    private func record(_ eventId: String, cursor: inout Cursor, seen: inout Set<String>) {
        guard seen.insert(eventId).inserted else { return }
        cursor.seenEventIds.append(eventId)
    }

    private func loadCursor() throws -> Cursor {
        guard fileManager.fileExists(atPath: cursorURL.path) else { return Cursor() }
        let data = try Data(contentsOf: cursorURL)
        return (try? JSONDecoder().decode(Cursor.self, from: data)) ?? Cursor()
    }

    private func saveCursor(_ cursor: Cursor) throws {
        try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inboxDirectory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cursor)
        try data.write(to: cursorURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorURL.path)
    }
}

/// Hook payload fields documented by Codex. Unknown fields are intentionally
/// ignored and prompt/tool contents are never persisted.
public struct CodexHookLifecycleInput: Codable, Sendable, Equatable {
    public let sessionId: String
    public let hookEventName: String
    public let turnId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case turnId = "turn_id"
    }
}

/// Pure helper entry point used by the executable and unit tests.
public enum CodexLifecycleHelper {
    public static let cardIdEnvironmentKey = "KANBAN_CODE_CARD_ID"
    public static let sessionIdEnvironmentKey = "KANBAN_CODE_SESSION_ID"
    public static let attemptIdEnvironmentKey = "KANBAN_CODE_ATTEMPT_ID"
    public static let generationEnvironmentKey = "KANBAN_CODE_GENERATION"
    public static let backendEnvironmentKey = "KANBAN_CODE_BACKEND"
    public static let capabilityEnvironmentKey = "KANBAN_CODE_LIFECYCLE_CAPABILITY"
    public static let basePathEnvironmentKey = "KANBAN_CODE_STATE_DIRECTORY"

    @discardableResult
    public static func emit(
        command: String,
        standardInput: Data = Data(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CodexLifecycleAppendResult? {
        guard let cardId = environment[cardIdEnvironmentKey],
              let expectedSessionId = environment[sessionIdEnvironmentKey],
              let attemptId = environment[attemptIdEnvironmentKey],
              let generationString = environment[generationEnvironmentKey],
              let generation = Int(generationString),
              let backendString = environment[backendEnvironmentKey],
              let backend = CodexRuntimeBackend(rawValue: backendString), backend != .unknown,
              let capability = environment[capabilityEnvironmentKey] else {
            // External/unmanaged sessions have no per-attempt binding. Their
            // hooks remain observational and cannot forge precise lifecycle.
            return nil
        }

        let kind: CodexLifecycleEventKind
        let sessionId: String
        let turnId: String?
        switch command {
        case "review-ready":
            kind = .reviewReady
            sessionId = expectedSessionId
            turnId = nil
        case "hook-event":
            guard standardInput.count <= CodexLifecycleInboxWriter.maximumEventBytes else {
                throw CodexLifecycleInboxError.eventTooLarge(
                    actual: standardInput.count,
                    maximum: CodexLifecycleInboxWriter.maximumEventBytes
                )
            }
            let input = try JSONDecoder().decode(CodexHookLifecycleInput.self, from: standardInput)
            guard backend == .cliTmux || input.sessionId == expectedSessionId else {
                throw CodexLifecycleInboxError.invalidEnvelope("hook session does not match launch binding")
            }
            // CLI launches know the owned tmux transport before Codex creates
            // its internal session UUID. The per-attempt capability and tmux
            // ownership tag bind the hook, so lifecycle envelopes retain that
            // stable transport identifier. Other backends require an exact
            // protocol session match.
            sessionId = backend == .cliTmux ? expectedSessionId : input.sessionId
            turnId = input.turnId
            switch input.hookEventName {
            case "SessionStart", "UserPromptSubmit": kind = .running
            case "PermissionRequest": kind = .waitingForApproval
            case "Stop": kind = .stopped
            default: return nil
            }
        default:
            throw CodexLifecycleInboxError.invalidEnvelope("unsupported helper command")
        }

        let envelope = CodexLifecycleEnvelope(
            cardId: cardId,
            sessionId: sessionId,
            attemptId: attemptId,
            generation: generation,
            kind: kind,
            backend: backend,
            turnId: turnId,
            capability: capability
        )
        let writer = CodexLifecycleInboxWriter(basePath: environment[basePathEnvironmentKey])
        return try await writer.append(envelope)
    }
}
