import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex lifecycle inbox")
struct CodexLifecycleInboxTests {
    private let capability = String(repeating: "ab", count: 32)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-code-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func envelope(
        id: String = UUID().uuidString,
        sessionId: String = "session-1",
        generation: Int = 2,
        kind: CodexLifecycleEventKind = .reviewReady,
        capability: String? = nil
    ) -> CodexLifecycleEnvelope {
        CodexLifecycleEnvelope(
            id: id,
            cardId: "card-1",
            sessionId: sessionId,
            attemptId: "attempt-1",
            generation: generation,
            kind: kind,
            backend: .cliTmux,
            turnId: "turn-1",
            sequence: 7,
            occurredAt: Date(timeIntervalSince1970: 1_750_000_000),
            capability: capability ?? self.capability
        )
    }

    private func binding(capability: String? = nil) -> CodexLifecycleExpectedBinding {
        CodexLifecycleExpectedBinding(
            cardId: "card-1",
            sessionId: "session-1",
            attemptId: "attempt-1",
            generation: 2,
            backend: .cliTmux,
            capability: capability ?? self.capability
        )
    }

    @Test("Atomic writer and reader normalize an authenticated review-ready event")
    func authenticatedRoundTrip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CodexLifecycleInboxWriter(basePath: directory.path)
        let reader = CodexLifecycleInboxReader(basePath: directory.path)

        let result = try await writer.append(envelope(id: "event-1"))
        #expect(result.rotatedEventCount == 0)

        let batch = try await reader.drain(bindings: ["card-1": binding()])
        #expect(batch.diagnostics.isEmpty)
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.id == "event-1")
        #expect(batch.events.first?.kind == .reviewReady)
        #expect(batch.events.first?.watermark.generation == 2)
        #expect(batch.events.first?.watermark.turnId == "turn-1")
        try await reader.acknowledge(batch)

        let inbox = directory.appendingPathComponent("codex-lifecycle-inbox")
        let cursorAttributes = try FileManager.default.attributesOfItem(
            atPath: inbox.appendingPathComponent("cursor.json").path
        )
        #expect((cursorAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Persistent cursor rejects an event ID replay")
    func replayIsDeduplicated() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CodexLifecycleInboxWriter(basePath: directory.path)
        let reader = CodexLifecycleInboxReader(basePath: directory.path)

        try await writer.append(envelope(id: "same-event"))
        let first = try await reader.drain(bindings: ["card-1": binding()])
        #expect(first.events.count == 1)
        try await reader.acknowledge(first)

        try await writer.append(envelope(id: "same-event", kind: .running))
        let replay = try await reader.drain(bindings: ["card-1": binding()])
        #expect(replay.events.isEmpty)
        #expect(replay.diagnostics.map(\.reason) == [.duplicate])
        try await reader.acknowledge(replay)
    }

    @Test("Cross-session, stale generation, and wrong capability are rejected")
    func bindingValidation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CodexLifecycleInboxWriter(basePath: directory.path)
        let reader = CodexLifecycleInboxReader(basePath: directory.path)

        try await writer.append(envelope(id: "wrong-session", sessionId: "session-2"))
        try await writer.append(envelope(id: "stale", generation: 1))
        try await writer.append(envelope(
            id: "wrong-capability",
            capability: String(repeating: "cd", count: 32)
        ))

        let batch = try await reader.drain(bindings: ["card-1": binding()])
        #expect(batch.events.isEmpty)
        #expect(batch.diagnostics.map(\.reason).filter { $0 == .bindingMismatch }.count == 2)
        #expect(batch.diagnostics.map(\.reason).contains(.invalidCapability))
    }

    @Test("Oversized and malformed payloads are bounded and diagnosed")
    func invalidPayloads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let smallWriter = CodexLifecycleInboxWriter(basePath: directory.path, maximumEventBytes: 32)

        await #expect(throws: CodexLifecycleInboxError.self) {
            try await smallWriter.append(envelope())
        }

        let pending = directory
            .appendingPathComponent("codex-lifecycle-inbox", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: pending.appendingPathComponent("malformed.json"))
        try Data(repeating: 0x41, count: 65).write(to: pending.appendingPathComponent("oversized.json"))

        let reader = CodexLifecycleInboxReader(basePath: directory.path, maximumEventBytes: 64)
        let batch = try await reader.drain(bindings: [:])
        #expect(Set(batch.diagnostics.map(\.reason)) == Set([.malformed, .tooLarge]))
    }

    @Test("Queue rotation keeps only the configured newest event count")
    func boundedBacklogRotation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CodexLifecycleInboxWriter(basePath: directory.path, maximumQueuedEvents: 2)

        try await writer.append(envelope(id: "one"))
        try await writer.append(envelope(id: "two"))
        let third = try await writer.append(envelope(id: "three"))
        #expect(third.rotatedEventCount == 1)

        let reader = CodexLifecycleInboxReader(basePath: directory.path)
        let batch = try await reader.drain(bindings: ["card-1": binding()])
        #expect(batch.events.count == 2)
        #expect(Set(batch.events.map(\.id)) == Set(["two", "three"]))
    }

    @Test("Helper emits review-ready and maps Stop to ordinary stop")
    func helperNormalization() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            CodexLifecycleHelper.cardIdEnvironmentKey: "card-1",
            CodexLifecycleHelper.sessionIdEnvironmentKey: "session-1",
            CodexLifecycleHelper.attemptIdEnvironmentKey: "attempt-1",
            CodexLifecycleHelper.generationEnvironmentKey: "2",
            CodexLifecycleHelper.backendEnvironmentKey: CodexRuntimeBackend.cliTmux.rawValue,
            CodexLifecycleHelper.capabilityEnvironmentKey: capability,
            CodexLifecycleHelper.basePathEnvironmentKey: directory.path,
        ]

        try await CodexLifecycleHelper.emit(command: "review-ready", environment: environment)
        // Codex creates its own UUID after the tmux transport is launched.
        // Capability-bound CLI events retain the stable owned tmux identity.
        let stop = #"{"session_id":"codex-generated-uuid","hook_event_name":"Stop","turn_id":"turn-2"}"#
        try await CodexLifecycleHelper.emit(
            command: "hook-event",
            standardInput: Data(stop.utf8),
            environment: environment
        )

        let reader = CodexLifecycleInboxReader(basePath: directory.path)
        let batch = try await reader.drain(bindings: ["card-1": binding()])
        #expect(batch.events.map(\.kind).contains(.reviewReady))
        #expect(batch.events.map(\.kind).contains(.stopped))
        #expect(batch.events.filter { $0.kind == .reviewReady }.count == 1)
        #expect(batch.events.allSatisfy { $0.cardId == "card-1" })
    }

    @Test("Unmanaged hooks remain non-authorizing")
    func helperNeedsManagedBinding() async throws {
        let result = try await CodexLifecycleHelper.emit(
            command: "review-ready",
            environment: [:]
        )
        #expect(result == nil)
    }

    @Test("Capability generation is 256-bit lowercase hex")
    func capabilityGeneration() throws {
        let generated = try CodexLifecycleCapability.generate()
        #expect(CodexLifecycleCapability.isValid(generated))
        #expect(CodexLifecycleCapability.constantTimeEquals(generated, generated))
        #expect(!CodexLifecycleCapability.constantTimeEquals(generated, capability))
        #expect(!CodexLifecycleCapability.constantTimeEquals(generated, generated + "00"))
    }
}

@Suite("Codex hook installer")
struct CodexHookInstallerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-code-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Helper deployment verifies the bundled and installed hashes")
    func deploysOnlyVerifiedHelper() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source-helper")
        let destination = directory.appendingPathComponent("installed-helper")
        try Data("trusted helper".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let hash = try CodexHookInstaller.sha256(path: source.path)

        _ = try CodexHookInstaller.deployHelper(
            from: source.path,
            expectedSHA256: hash,
            helperPath: destination.path
        )
        #expect(CodexHookInstaller.helperMatches(path: destination.path, expectedSHA256: hash))
        #expect(throws: CodexLifecycleInboxError.self) {
            _ = try CodexHookInstaller.deployHelper(
                from: source.path,
                expectedSHA256: String(repeating: "0", count: 64),
                helperPath: destination.path
            )
        }
    }

    @Test("Install merges idempotently and uninstall preserves unrelated config")
    func mergeAndUninstall() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooksPath = directory.appendingPathComponent("hooks.json").path
        let helperPath = "/usr/local/bin/kanban-code-lifecycle"
        let existing = #"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/usr/local/bin/other-hook"}]}]}}"#
        try Data(existing.utf8).write(to: URL(fileURLWithPath: hooksPath))

        try CodexHookInstaller.install(hooksPath: hooksPath, helperPath: helperPath)
        try CodexHookInstaller.install(hooksPath: hooksPath, helperPath: helperPath)
        #expect(CodexHookInstaller.isInstalled(hooksPath: hooksPath, helperPath: helperPath))
        #expect(FileManager.default.fileExists(atPath: hooksPath + ".kanban-code.backup"))

        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: hooksPath))) as? [String: Any]
        )
        #expect(root["theme"] as? String == "dark")
        var hooks = try #require(root["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let stopEntries = try #require(stopGroups.first?["hooks"] as? [[String: Any]])
        #expect(stopEntries.count == 2)

        try CodexHookInstaller.uninstall(hooksPath: hooksPath, helperPath: helperPath)
        #expect(!CodexHookInstaller.isInstalled(hooksPath: hooksPath, helperPath: helperPath))

        root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: hooksPath))) as? [String: Any]
        )
        hooks = try #require(root["hooks"] as? [String: Any])
        let remainingGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let remaining = try #require(remainingGroups.first?["hooks"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect(remaining.first?["command"] as? String == "/usr/local/bin/other-hook")
        #expect(root["theme"] as? String == "dark")
    }

    @Test("Installer rejects paths that would require shell escaping")
    func rejectUnsafePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: CodexLifecycleInboxError.self) {
            try CodexHookInstaller.install(
                hooksPath: directory.appendingPathComponent("hooks.json").path,
                helperPath: "/tmp/helper;touch-bad"
            )
        }
    }

    @Test("Installer refuses to overwrite malformed user config")
    func preserveMalformedConfig() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooksPath = directory.appendingPathComponent("hooks.json").path
        let original = "not-json"
        try original.write(toFile: hooksPath, atomically: true, encoding: .utf8)

        #expect(throws: CodexLifecycleInboxError.self) {
            try CodexHookInstaller.install(
                hooksPath: hooksPath,
                helperPath: "/usr/local/bin/kanban-code-lifecycle"
            )
        }
        #expect(try String(contentsOfFile: hooksPath, encoding: .utf8) == original)
    }
}
