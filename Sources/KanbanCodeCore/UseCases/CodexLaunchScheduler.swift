import Foundation

/// Immutable queue input. Queue order is persisted by the card's creation time
/// and made deterministic with its ID as a tie-breaker.
public struct CodexQueuedTask: Sendable, Equatable, Identifiable {
    public var id: String { cardId }
    public var cardId: String
    public var backend: CodexRuntimeBackend
    public var enqueuedAt: Date
    public var projectPath: String
    public var prompt: String

    public init(
        cardId: String,
        backend: CodexRuntimeBackend,
        enqueuedAt: Date,
        projectPath: String,
        prompt: String
    ) {
        self.cardId = cardId
        self.backend = backend
        self.enqueuedAt = enqueuedAt
        self.projectPath = projectPath
        self.prompt = prompt
    }
}

public enum CodexLaunchOutcome: Sendable, Equatable {
    case launched(cardId: String, binding: CodexExecutionBinding)
    case failed(cardId: String, message: String)
    case uncertain(cardId: String, message: String)
}

public enum CodexLaunchRecoveryOutcome: Sendable, Equatable {
    case notStarted(cardId: String)
    case running(cardId: String, binding: CodexExecutionBinding)
    case stopped(cardId: String, binding: CodexExecutionBinding?)
    case uncertain(cardId: String, message: String)
}

/// Serialized, durable auto-claim coordinator. A lease is committed before a
/// runtime side effect and recovery runs before the first scheduling pass.
public actor CodexLaunchScheduler {
    public typealias AttemptID = @Sendable () -> String
    public typealias Clock = @Sendable () -> Date

    private let stateStore: CodexRuntimeStateStore
    private let runtimes: [CodexRuntimeBackend: any CodexRuntimePort]
    private let makeAttemptID: AttemptID
    private let now: Clock
    private var didRecover = false
    private var isScheduling = false

    public init(
        stateStore: CodexRuntimeStateStore,
        runtimes: [CodexRuntimeBackend: any CodexRuntimePort],
        makeAttemptID: @escaping AttemptID = { UUID().uuidString },
        now: @escaping Clock = { .now }
    ) {
        self.stateStore = stateStore
        self.runtimes = runtimes
        self.makeAttemptID = makeAttemptID
        self.now = now
    }

    /// Runs one atomic scheduling pass. Queued work for an inactive backend is
    /// deliberately ignored; already-running work for every backend still
    /// counts against the global capacity.
    @discardableResult
    public func schedule(
        queuedTasks: [CodexQueuedTask],
        activeBackend: CodexRuntimeBackend,
        maxConcurrency: Int
    ) async throws -> [CodexLaunchOutcome] {
        // Actors are re-entrant at every await. Reserve the whole scheduling
        // pass before the first suspension so overlapping UI refreshes cannot
        // claim and launch the same card twice.
        guard !isScheduling else { return [] }
        isScheduling = true
        defer { isScheduling = false }

        if !didRecover {
            _ = await recoverPersistedAttempts()
            didRecover = true
        }

        var states = try await stateStore.readAll()
        let capacity = CodexBoardSettings.clampedConcurrency(maxConcurrency)
        var available = max(0, capacity - states.values.filter(Self.occupiesSlot).count)
        guard available > 0, runtimes[activeBackend] != nil else { return [] }

        let candidates = queuedTasks
            .filter { $0.backend == activeBackend }
            .filter { task in
                guard let state = states[task.cardId] else { return true }
                return state.lifecycle.phase == .queued
            }
            .sorted {
                if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
                return $0.cardId < $1.cardId
            }

        var outcomes: [CodexLaunchOutcome] = []
        for task in candidates where available > 0 {
            guard let runtime = runtimes[task.backend] else { continue }
            let previous = states[task.cardId]
            let generation = (previous?.launchLease?.generation ?? 0) + 1
            let attemptedAt = now()
            let lease = LaunchLease(
                attemptId: makeAttemptID(),
                backend: task.backend,
                generation: generation,
                lifecycleCapability: try CodexLifecycleCapability.generate(),
                acquiredAt: attemptedAt
            )
            var claimed = previous ?? CardRuntimeState(cardId: task.cardId)
            claimed.lifecycle = LifecycleSnapshot(
                phase: .launching,
                telemetryQuality: .precise
            )
            claimed.launchLease = lease
            claimed.updatedAt = attemptedAt

            // This durable write is the commit point before any external effect.
            try await stateStore.upsert(claimed)
            states[task.cardId] = claimed
            available -= 1

            let request = CodexRuntimeLaunchRequest(
                cardId: task.cardId,
                attemptId: lease.attemptId,
                generation: generation,
                lifecycleCapability: lease.lifecycleCapability!,
                projectPath: task.projectPath,
                prompt: task.prompt
            )

            do {
                let receipt = try await runtime.launch(request)
                claimed.lifecycle = LifecycleSnapshot(
                    phase: .running,
                    telemetryQuality: receipt.binding.telemetryQuality
                )
                claimed.executionBinding = receipt.binding
                claimed.updatedAt = now()
                try await stateStore.upsert(claimed)
                states[task.cardId] = claimed
                outcomes.append(.launched(cardId: task.cardId, binding: receipt.binding))
            } catch {
                let runtimeError = error as? CodexRuntimeError
                let uncertain = runtimeError?.mayHaveStartedWork == true
                if case .partialLaunch(_, let binding)? = runtimeError {
                    claimed.executionBinding = binding
                }
                claimed.lifecycle = LifecycleSnapshot(
                    phase: .waiting,
                    waitReason: uncertain ? .launchUncertain : .fault,
                    telemetryQuality: .limited
                )
                claimed.updatedAt = now()
                try await stateStore.upsert(claimed)
                states[task.cardId] = claimed
                let message = runtimeError?.localizedDescription ?? error.localizedDescription
                if uncertain {
                    outcomes.append(.uncertain(cardId: task.cardId, message: message))
                } else {
                    // A definite pre-launch failure releases the slot immediately.
                    available += 1
                    outcomes.append(.failed(cardId: task.cardId, message: message))
                }
            }
        }
        return outcomes
    }

    /// Reconciles all persisted slot-holding attempts. This is safe to call
    /// repeatedly and never creates new runtime work.
    public func recoverPersistedAttempts() async -> [CodexLaunchRecoveryOutcome] {
        guard let states = try? await stateStore.readAll() else { return [] }
        var outcomes: [CodexLaunchRecoveryOutcome] = []
        for var state in states.values where Self.occupiesSlot(state) {
            guard let lease = state.launchLease, let runtime = runtimes[lease.backend] else {
                continue
            }
            let request = CodexRuntimeRecoveryRequest(
                cardId: state.cardId,
                lease: lease,
                binding: state.executionBinding
            )
            let result = await runtime.recover(request)
            switch result {
            case .notStarted:
                state.lifecycle = LifecycleSnapshot(phase: .queued, telemetryQuality: .precise)
                outcomes.append(.notStarted(cardId: state.cardId))
            case .running(let binding):
                state.lifecycle = LifecycleSnapshot(
                    phase: .running,
                    telemetryQuality: binding.telemetryQuality
                )
                state.executionBinding = binding
                outcomes.append(.running(cardId: state.cardId, binding: binding))
            case .stopped(let binding):
                state.lifecycle = LifecycleSnapshot(
                    phase: .waiting,
                    waitReason: .ordinaryStop,
                    telemetryQuality: .precise
                )
                if let binding { state.executionBinding = binding }
                outcomes.append(.stopped(cardId: state.cardId, binding: binding))
            case .uncertain(let message):
                state.lifecycle = LifecycleSnapshot(
                    phase: .waiting,
                    waitReason: .launchUncertain,
                    telemetryQuality: .limited
                )
                outcomes.append(.uncertain(cardId: state.cardId, message: message))
            }
            state.updatedAt = now()
            try? await stateStore.upsert(state)
        }
        return outcomes
    }

    public static func occupiesSlot(_ state: CardRuntimeState) -> Bool {
        guard state.launchLease != nil else { return false }
        switch state.lifecycle.phase {
        case .launching, .running, .unknown:
            return true
        case .waiting:
            return state.lifecycle.waitReason == .disconnected || state.lifecycle.waitReason == .launchUncertain
        case .queued, .inReview, .done:
            return false
        }
    }
}
