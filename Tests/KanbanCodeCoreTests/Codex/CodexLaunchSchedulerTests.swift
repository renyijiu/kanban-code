import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex launch scheduler")
struct CodexLaunchSchedulerTests {
    actor FakeRuntime: CodexRuntimePort {
        nonisolated let backend: CodexRuntimeBackend
        var launched: [CodexRuntimeLaunchRequest] = []
        var recoveries: [CodexRuntimeRecoveryRequest] = []
        var launchErrors: [String: CodexRuntimeError] = [:]
        var recoveryResults: [String: CodexRuntimeRecoveryResult] = [:]

        init(backend: CodexRuntimeBackend) {
            self.backend = backend
        }

        func launch(_ request: CodexRuntimeLaunchRequest) async throws -> CodexRuntimeLaunchReceipt {
            launched.append(request)
            if let error = launchErrors[request.cardId] { throw error }
            return CodexRuntimeLaunchReceipt(
                binding: CodexExecutionBinding(
                    backend: backend,
                    ownership: .managed,
                    evidence: .boardCreated,
                    telemetryQuality: .precise,
                    threadId: backend == .app ? "thread-\(request.cardId)" : nil,
                    tmuxSessionName: backend == .cliTmux ? "tmux-\(request.cardId)" : nil
                )
            )
        }

        func recover(_ request: CodexRuntimeRecoveryRequest) async -> CodexRuntimeRecoveryResult {
            recoveries.append(request)
            return recoveryResults[request.cardId] ?? .notStarted
        }

        func sendFeedback(_ request: CodexRuntimeFeedbackRequest) async throws {}

        func setLaunchError(_ error: CodexRuntimeError, cardId: String) {
            launchErrors[cardId] = error
        }

        func setRecovery(_ result: CodexRuntimeRecoveryResult, cardId: String) {
            recoveryResults[cardId] = result
        }

        func launchedCardIds() -> [String] { launched.map(\.cardId) }
    }

    actor SuspendedRuntime: CodexRuntimePort {
        nonisolated let backend: CodexRuntimeBackend = .cliTmux
        private var launches = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func launch(_ request: CodexRuntimeLaunchRequest) async throws -> CodexRuntimeLaunchReceipt {
            launches += 1
            await withCheckedContinuation { continuation = $0 }
            return .init(binding: .init(
                backend: .cliTmux,
                ownership: .managed,
                evidence: .boardCreated,
                telemetryQuality: .precise,
                tmuxSessionName: "tmux-\(request.cardId)"
            ))
        }

        func recover(_ request: CodexRuntimeRecoveryRequest) async -> CodexRuntimeRecoveryResult { .notStarted }
        func sendFeedback(_ request: CodexRuntimeFeedbackRequest) async throws {}
        func launchCount() -> Int { launches }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func makeStore() throws -> (CodexRuntimeStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (CodexRuntimeStateStore(basePath: directory.path), directory)
    }

    private func task(
        _ id: String,
        backend: CodexRuntimeBackend = .cliTmux,
        order: TimeInterval
    ) -> CodexQueuedTask {
        CodexQueuedTask(
            cardId: id,
            backend: backend,
            enqueuedAt: Date(timeIntervalSince1970: order),
            projectPath: "/tmp/project",
            prompt: "work on \(id)"
        )
    }

    @Test("Claims FIFO up to the bounded global capacity")
    func fifoAndCapacity() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = FakeRuntime(backend: .cliTmux)
        let scheduler = CodexLaunchScheduler(
            stateStore: store,
            runtimes: [.cliTmux: cli],
            makeAttemptID: { "attempt" }
        )

        let outcomes = try await scheduler.schedule(
            queuedTasks: [task("third", order: 3), task("first", order: 1), task("second", order: 2)],
            activeBackend: .cliTmux,
            maxConcurrency: 2
        )

        #expect(await cli.launchedCardIds() == ["first", "second"])
        #expect(outcomes.count == 2)
        #expect(try await store.state(for: "third") == nil)
        #expect(try await store.state(for: "first")?.lifecycle.phase == .running)
    }

    @Test("Overlapping scheduling passes cannot launch the same card twice")
    func overlappingPassesAreSerialized() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = SuspendedRuntime()
        let scheduler = CodexLaunchScheduler(stateStore: store, runtimes: [.cliTmux: runtime])
        let queued = [task("one", order: 1)]

        let first = Task {
            try await scheduler.schedule(queuedTasks: queued, activeBackend: .cliTmux, maxConcurrency: 1)
        }
        while await runtime.launchCount() == 0 { await Task.yield() }
        let overlapping = try await scheduler.schedule(
            queuedTasks: queued,
            activeBackend: .cliTmux,
            maxConcurrency: 1
        )
        #expect(overlapping.isEmpty)
        await runtime.release()
        _ = try await first.value
        #expect(await runtime.launchCount() == 1)
    }

    @Test("Capacity is clamped to 1 through 32")
    func clampsCapacity() async throws {
        let (lowerStore, lowerDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: lowerDirectory) }
        let lowerRuntime = FakeRuntime(backend: .cliTmux)
        let lower = CodexLaunchScheduler(stateStore: lowerStore, runtimes: [.cliTmux: lowerRuntime])
        _ = try await lower.schedule(
            queuedTasks: [task("one", order: 1), task("two", order: 2)],
            activeBackend: .cliTmux,
            maxConcurrency: -10
        )
        #expect(await lowerRuntime.launchedCardIds().count == 1)

        let (upperStore, upperDirectory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: upperDirectory) }
        let upperRuntime = FakeRuntime(backend: .cliTmux)
        let upper = CodexLaunchScheduler(stateStore: upperStore, runtimes: [.cliTmux: upperRuntime])
        let tasks = (0..<40).map { task("card-\($0)", order: TimeInterval($0)) }
        _ = try await upper.schedule(queuedTasks: tasks, activeBackend: .cliTmux, maxConcurrency: 100)
        #expect(await upperRuntime.launchedCardIds().count == 32)
    }

    @Test("Inactive queue pauses while running work across modes consumes capacity")
    func inactiveQueueAndGlobalCapacity() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FakeRuntime(backend: .app)
        let cli = FakeRuntime(backend: .cliTmux)
        let scheduler = CodexLaunchScheduler(stateStore: store, runtimes: [.app: app, .cliTmux: cli])

        try await store.upsert(
            CardRuntimeState(
                cardId: "app-running",
                lifecycle: .init(phase: .running, telemetryQuality: .precise),
                launchLease: .init(attemptId: "a", backend: .app, generation: 1)
            )
        )
        await app.setRecovery(
            .running(.init(
                backend: .app,
                ownership: .managed,
                evidence: .boardCreated,
                telemetryQuality: .precise,
                threadId: "thread-a"
            )),
            cardId: "app-running"
        )

        _ = try await scheduler.schedule(
            queuedTasks: [task("hidden-app", backend: .app, order: 1), task("visible-cli", order: 2)],
            activeBackend: .cliTmux,
            maxConcurrency: 2
        )

        #expect(await app.launchedCardIds().isEmpty)
        #expect(await cli.launchedCardIds() == ["visible-cli"])
    }

    @Test("Restart recovery does not duplicate running or uncertain work")
    func recoveryPreventsDuplicateLaunch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = FakeRuntime(backend: .cliTmux)
        let lease = LaunchLease(attemptId: "existing", backend: .cliTmux, generation: 4)
        try await store.upsert(
            CardRuntimeState(
                cardId: "leased",
                lifecycle: .init(phase: .launching, telemetryQuality: .precise),
                launchLease: lease
            )
        )
        await cli.setRecovery(.uncertain("transport unavailable"), cardId: "leased")
        let scheduler = CodexLaunchScheduler(stateStore: store, runtimes: [.cliTmux: cli])

        _ = try await scheduler.schedule(
            queuedTasks: [task("leased", order: 1), task("next", order: 2)],
            activeBackend: .cliTmux,
            maxConcurrency: 1
        )

        #expect(await cli.launchedCardIds().isEmpty)
        #expect(try await store.state(for: "leased")?.lifecycle.waitReason == .launchUncertain)
    }

    @Test("Definitely absent lease is safely relaunched with a new generation")
    func absentLeaseCanRelaunch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = FakeRuntime(backend: .cliTmux)
        try await store.upsert(
            CardRuntimeState(
                cardId: "leased",
                lifecycle: .init(phase: .launching, telemetryQuality: .precise),
                launchLease: .init(attemptId: "old", backend: .cliTmux, generation: 2)
            )
        )
        let scheduler = CodexLaunchScheduler(
            stateStore: store,
            runtimes: [.cliTmux: cli],
            makeAttemptID: { "new" }
        )

        _ = try await scheduler.schedule(
            queuedTasks: [task("leased", order: 1)],
            activeBackend: .cliTmux,
            maxConcurrency: 1
        )

        #expect(await cli.launchedCardIds() == ["leased"])
        #expect(await cli.launched.first?.generation == 3)
    }

    @Test("Definite launch failure releases capacity but uncertain failure retains it")
    func launchFailureSlotBehavior() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = FakeRuntime(backend: .cliTmux)
        await cli.setLaunchError(.notStarted("missing executable"), cardId: "first")
        await cli.setLaunchError(.launchUncertain("lost acknowledgement"), cardId: "third")
        let scheduler = CodexLaunchScheduler(stateStore: store, runtimes: [.cliTmux: cli])

        _ = try await scheduler.schedule(
            queuedTasks: [
                task("first", order: 1), task("second", order: 2),
                task("third", order: 3), task("fourth", order: 4),
            ],
            activeBackend: .cliTmux,
            maxConcurrency: 2
        )

        #expect(await cli.launchedCardIds() == ["first", "second", "third"])
        #expect(try await store.state(for: "first")?.lifecycle.waitReason == .fault)
        #expect(try await store.state(for: "third")?.lifecycle.waitReason == .launchUncertain)
        #expect(try await store.state(for: "fourth") == nil)
    }

    @Test("Partial App launch persists its acknowledged thread for recovery")
    func partialLaunchPersistsBinding() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = FakeRuntime(backend: .app)
        let binding = CodexExecutionBinding(
            backend: .app,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .limited,
            threadId: "thread-created"
        )
        await app.setLaunchError(
            .partialLaunch("turn acknowledgement lost", binding),
            cardId: "partial"
        )
        let scheduler = CodexLaunchScheduler(stateStore: store, runtimes: [.app: app])

        let outcomes = try await scheduler.schedule(
            queuedTasks: [task("partial", backend: .app, order: 1)],
            activeBackend: .app,
            maxConcurrency: 1
        )

        #expect(outcomes == [.uncertain(cardId: "partial", message: "turn acknowledgement lost")])
        #expect(try await store.state(for: "partial")?.executionBinding?.threadId == "thread-created")
        #expect(try await store.state(for: "partial")?.lifecycle.waitReason == .launchUncertain)
    }
}
