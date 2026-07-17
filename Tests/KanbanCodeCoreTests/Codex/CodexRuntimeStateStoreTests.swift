import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("CodexRuntimeStateStore")
struct CodexRuntimeStateStoreTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-code-runtime-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Runtime state persists independently from links")
    func roundTripIsIsolatedFromLinks() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexRuntimeStateStore(basePath: directory.path)
        let state = CardRuntimeState(
            cardId: "card-1",
            lifecycle: LifecycleSnapshot(
                phase: .waiting,
                waitReason: .approval,
                telemetryQuality: .precise
            ),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.upsert(state)

        #expect(try await store.state(for: "card-1") == state)
        let stateURL = directory.appendingPathComponent("codex-runtime-state.json")
        #expect(FileManager.default.fileExists(atPath: stateURL.path))
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("links.json").path))
    }

    @Test("Store replaces and removes state by card ID")
    func replaceAndRemove() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexRuntimeStateStore(basePath: directory.path)

        try await store.upsert(CardRuntimeState(cardId: "card-1", lifecycle: .init(phase: .queued)))
        try await store.upsert(CardRuntimeState(cardId: "card-1", lifecycle: .init(phase: .running)))
        #expect(try await store.state(for: "card-1")?.lifecycle.phase == .running)

        try await store.remove(cardId: "card-1")
        #expect(try await store.state(for: "card-1") == nil)
    }

    @Test("Legacy empty or absent store reads as no states")
    func missingStoreReadsEmpty() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexRuntimeStateStore(basePath: directory.path)

        #expect(try await store.readAll().isEmpty)
    }

    @Test("Corrupt state is backed up and fails closed")
    func corruptStoreFailsClosed() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("codex-runtime-state.json")
        try Data("not-json".utf8).write(to: stateURL)
        let store = CodexRuntimeStateStore(basePath: directory.path)

        await #expect(throws: CodexRuntimeStateStoreError.self) {
            try await store.readAll()
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.appendingPathExtension("bkp").path))
    }
}
