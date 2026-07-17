import Foundation
import KanbanCodeCore

struct CodexPendingAction: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case approval, input }
    let cardId: String
    let kind: Kind
    let title: String
    let details: String
    var id: String { cardId }
}

/// App-owned bridge that keeps runtime processes alive and applies the durable
/// scheduler without putting process ownership in SwiftUI views.
actor CodexBoardCoordinator {
    private enum LifecycleApplyResult {
        case acknowledged(CardRuntimeState?)
        case failed
    }
    struct ScheduleResult: Sendable {
        let outcomes: [CodexLaunchOutcome]
        let runtimeStates: [String: CardRuntimeState]
    }

    private let tmux: TmuxAdapter
    private let stateStore: CodexRuntimeStateStore
    private let appServerConnection: CodexAppServerConnection
    private let lifecycleInbox = CodexLifecycleInboxReader()
    private let onStateChanged: @Sendable (CardRuntimeState) -> Void
    private var scheduler: CodexLaunchScheduler?
    private var runtimes: [CodexRuntimeBackend: any CodexRuntimePort] = [:]
    private var appRuntimeUnavailableReason: String?
    private var appMonitorTasks: [Task<Void, Never>] = []
    private var appClient: CodexAppServerClient?
    private var pendingRequestsByCardId: [String: CodexAppServerRequest] = [:]
    private var pendingRequestsByThreadId: [String: CodexAppServerRequest] = [:]

    init(
        tmux: TmuxAdapter,
        stateStore: CodexRuntimeStateStore = CodexRuntimeStateStore(),
        appServerConnection: CodexAppServerConnection = .shared,
        onStateChanged: @escaping @Sendable (CardRuntimeState) -> Void
    ) {
        self.tmux = tmux
        self.stateStore = stateStore
        self.appServerConnection = appServerConnection
        self.onStateChanged = onStateChanged
    }

    func schedule(
        tasks: [CodexQueuedTask],
        activeBackend: CodexRuntimeBackend,
        maxConcurrency: Int
    ) async throws -> ScheduleResult {
        // Keep App Server monitoring alive even when CLI + tmux is the active
        // launch backend so imported Codex App sessions update promptly.
        if activeBackend != .app {
            _ = try? await makeSchedulerIfNeeded(activeBackend: .app)
        }
        let scheduler = try await makeSchedulerIfNeeded(activeBackend: activeBackend)
        if activeBackend == .app, let reason = appRuntimeUnavailableReason {
            throw CodexRuntimeError.unavailable(reason)
        }
        let outcomes = try await scheduler.schedule(
            queuedTasks: tasks,
            activeBackend: activeBackend,
            maxConcurrency: maxConcurrency
        )
        await bindBufferedRequests()
        return ScheduleResult(outcomes: outcomes, runtimeStates: try await stateStore.readAll())
    }

    func pendingAction(for cardId: String) -> CodexPendingAction? {
        guard let request = pendingRequestsByCardId[cardId] else { return nil }
        guard request.method == "item/tool/requestUserInput"
                || request.method == "item/commandExecution/requestApproval"
                || request.method == "item/fileChange/requestApproval"
                || request.method == "item/permissions/requestApproval" else { return nil }
        let isInput = request.method == "item/tool/requestUserInput"
        return CodexPendingAction(
            cardId: cardId,
            kind: isInput ? .input : .approval,
            title: isInput ? "Codex needs your input" : "Codex requests approval",
            details: request.params.humanReadableSummary(maxLength: 2_000)
        )
    }

    func respond(to cardId: String, approve: Bool? = nil, input: String? = nil) async throws {
        guard let request = pendingRequestsByCardId[cardId], let client = appClient else {
            throw CodexRuntimeError.invalidBinding("This Codex request is no longer pending")
        }
        let result: CodexJSONValue
        if request.method == "item/tool/requestUserInput" {
            let answer = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else {
                throw CodexRuntimeError.invalidBinding("Enter a response before sending")
            }
            let questionIDs = request.params.recursiveStrings(for: "id")
            result = .object([
                "answers": .object(Dictionary(uniqueKeysWithValues: questionIDs.map { id in
                    (id, .object(["answers": .array([.string(answer)])]))
                })),
            ])
        } else if request.method == "item/permissions/requestApproval" {
            let requested = request.params["permissions"] ?? .object([:])
            result = .object([
                "permissions": approve == true ? requested : .object([:]),
                "scope": .string("turn"),
            ])
        } else {
            result = .object(["decision": .string(approve == true ? "accept" : "decline")])
        }
        try await client.respond(to: request, result: result)
        pendingRequestsByCardId.removeValue(forKey: cardId)
        try await emitLifecycle(kind: .running, cardId: cardId, source: "board:response")
    }

    func acceptReview(cardId: String) async throws {
        guard let state = try await stateStore.state(for: cardId), state.lifecycle.phase == .inReview else {
            throw CodexRuntimeError.invalidBinding("This card is no longer waiting for review")
        }
        try await emitLifecycle(kind: .accepted, cardId: cardId, source: "board:accept")
    }

    func markReviewReady(cardId: String) async throws {
        guard let state = try await stateStore.state(for: cardId),
              state.lifecycle.phase == .running || state.lifecycle.phase == .waiting else {
            throw CodexRuntimeError.invalidBinding("This card is not currently running or waiting")
        }
        try await emitLifecycle(kind: .reviewReady, cardId: cardId, source: "board:manual-review")
    }

    func continueReview(cardId: String, feedback: String) async throws {
        let body = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CodexRuntimeError.invalidBinding("Enter revision feedback") }
        guard let state = try await stateStore.state(for: cardId),
              state.lifecycle.phase == .inReview,
              let binding = state.executionBinding else {
            throw CodexRuntimeError.invalidBinding("This card has no active review binding")
        }
        _ = try await makeSchedulerIfNeeded(activeBackend: binding.backend)
        guard let runtime = runtimes[binding.backend] else {
            throw CodexRuntimeError.unavailable("The original Codex runtime is unavailable")
        }
        try await runtime.sendFeedback(.init(cardId: cardId, binding: binding, body: body))
        try await emitLifecycle(kind: .running, cardId: cardId, source: "board:continue")
    }

    func drainLifecycleInbox() async {
        guard await lifecycleInbox.hasPendingEvents() else { return }
        guard let states = try? await stateStore.readAll() else { return }
        let bindings = Dictionary(uniqueKeysWithValues: states.values.compactMap { state -> (String, CodexLifecycleExpectedBinding)? in
            guard let lease = state.launchLease,
                  let capability = lease.lifecycleCapability,
                  let execution = state.executionBinding,
                  let sessionID = execution.sessionId ?? execution.threadId ?? execution.tmuxSessionName else {
                return nil
            }
            return (state.cardId, CodexLifecycleExpectedBinding(
                cardId: state.cardId,
                sessionId: sessionID,
                attemptId: lease.attemptId,
                generation: lease.generation,
                backend: lease.backend,
                capability: capability
            ))
        })
        guard let batch = try? await lifecycleInbox.drain(bindings: bindings) else { return }
        var canAcknowledge = true
        for event in batch.events {
            switch await apply(event: event) {
            case .acknowledged:
                continue
            case .failed:
                canAcknowledge = false
            }
        }
        if canAcknowledge {
            try? await lifecycleInbox.acknowledge(batch)
        }
    }

    private func makeSchedulerIfNeeded(activeBackend: CodexRuntimeBackend) async throws -> CodexLaunchScheduler {
        var addedRuntime = false
        if runtimes[.cliTmux] == nil {
            runtimes[.cliTmux] = CodexCLITmuxRuntime(
                tmux: tmux,
                metadata: CodexTmuxMetadataAdapter()
            )
            addedRuntime = true
        }
        if activeBackend == .app {
            do {
                let client = try await appServerConnection.client()
                let clientChanged = appClient.map { $0 !== client } ?? true
                if runtimes[.app] == nil || clientChanged {
                    appMonitorTasks.forEach { $0.cancel() }
                    appMonitorTasks.removeAll()
                    runtimes[.app] = CodexAppServerRuntime(client: client)
                    appClient = client
                    addedRuntime = true
                    startAppServerMonitors(client: client)
                }
                appRuntimeUnavailableReason = nil
            } catch {
                appRuntimeUnavailableReason = "Codex App mode is unavailable: \(error.localizedDescription)"
            }
        }
        if let scheduler, !addedRuntime { return scheduler }
        let created = CodexLaunchScheduler(stateStore: stateStore, runtimes: runtimes)
        scheduler = created
        return created
    }

    private func startAppServerMonitors(client: CodexAppServerClient) {
        guard appMonitorTasks.isEmpty else { return }
        appMonitorTasks = [
            Task { [weak self] in
                let stream = await client.notifications()
                for await notification in stream {
                    await self?.consume(notification: notification)
                }
            },
            Task { [weak self] in
                let stream = await client.serverRequests()
                for await request in stream {
                    await self?.consume(serverRequest: request)
                }
            },
        ]
    }

    private func consume(notification: CodexAppServerNotification) async {
        guard let threadID = notification.params.recursiveString(for: "threadId")
                ?? notification.params.recursiveString(for: "thread_id") else { return }

        let kind: CodexLifecycleEventKind
        if let changed = try? notification.decodeParams(as: CodexThreadStatusChanged.self) {
            if changed.status.waitingOnApproval {
                kind = .waitingForApproval
            } else if changed.status.waitingOnUserInput {
                kind = .waitingForInput
            } else {
                switch changed.status.type.lowercased() {
                case "active", "running", "inprogress": kind = .running
                case "idle", "stopped", "completed": kind = .stopped
                default: return
                }
            }
        } else if notification.method.contains("turn/completed") {
            kind = .stopped
        } else {
            return
        }
        await apply(
            kind: kind,
            threadID: threadID,
            turnID: notification.params.recursiveString(for: "turnId")
                ?? notification.params.recursiveString(for: "turn_id"),
            source: notification.method
        )
    }

    private func consume(serverRequest: CodexAppServerRequest) async {
        guard let threadID = serverRequest.params.recursiveString(for: "threadId")
                ?? serverRequest.params.recursiveString(for: "thread_id") else { return }
        pendingRequestsByThreadId[threadID] = serverRequest
        await bindBufferedRequests()
        let kind: CodexLifecycleEventKind = serverRequest.method.contains("requestUserInput")
            ? .waitingForInput
            : .waitingForApproval
        await apply(
            kind: kind,
            threadID: threadID,
            turnID: serverRequest.params.recursiveString(for: "turnId")
                ?? serverRequest.params.recursiveString(for: "turn_id"),
            source: serverRequest.method
        )
    }

    private func bindBufferedRequests() async {
        guard !pendingRequestsByThreadId.isEmpty,
              let states = try? await stateStore.readAll() else { return }
        for state in states.values {
            guard let threadID = state.executionBinding?.threadId,
                  let request = pendingRequestsByThreadId.removeValue(forKey: threadID) else { continue }
            pendingRequestsByCardId[state.cardId] = request
        }
    }

    private func emitLifecycle(kind: CodexLifecycleEventKind, cardId: String, source: String) async throws {
        guard let state = try await stateStore.state(for: cardId) else {
            throw CodexRuntimeError.invalidBinding("The card no longer has runtime state")
        }
        let eventID = UUID().uuidString
        let event = CodexLifecycleEvent(
            id: eventID,
            cardId: cardId,
            kind: kind,
            watermark: LifecycleEventWatermark(
                eventId: eventID,
                source: source,
                generation: state.launchLease?.generation,
                turnId: state.executionBinding?.turnId,
                occurredAt: .now
            ),
            telemetryQuality: .precise
        )
        if case .failed = await apply(event: event) {
            throw CodexRuntimeError.unavailable("Could not persist the Codex lifecycle response")
        }
    }

    private func apply(
        kind: CodexLifecycleEventKind,
        threadID: String,
        turnID: String? = nil,
        source: String
    ) async {
        guard let states = try? await stateStore.readAll(),
              let state = states.values.first(where: { $0.executionBinding?.threadId == threadID }) else {
            return
        }
        let eventID = UUID().uuidString
        let event = CodexLifecycleEvent(
            id: eventID,
            cardId: state.cardId,
            kind: kind,
            watermark: LifecycleEventWatermark(
                eventId: eventID,
                source: "codex-app-server:\(source)",
                generation: state.launchLease?.generation,
                turnId: turnID ?? state.executionBinding?.turnId,
                occurredAt: .now
            ),
            telemetryQuality: .precise
        )
        _ = await apply(event: event)
    }

    private func apply(event: CodexLifecycleEvent) async -> LifecycleApplyResult {
        let reduction: CodexLifecycleReduction
        do {
            reduction = try await stateStore.applyLifecycleEvent(event)
        } catch {
            return .failed
        }
        let state: CardRuntimeState
        switch reduction {
        case .applied(let reduced), .conflicted(let reduced):
            state = reduced
        case .duplicate, .ignoredStale:
            return .acknowledged(nil)
        }
        onStateChanged(state)
        return .acknowledged(state)
    }
}

private extension CodexJSONValue {
    func recursiveString(for key: String) -> String? {
        switch self {
        case .object(let object):
            if case .string(let value)? = object[key] { return value }
            for value in object.values {
                if let found = value.recursiveString(for: key) { return found }
            }
            return nil
        case .array(let values):
            for value in values {
                if let found = value.recursiveString(for: key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    func recursiveStrings(for key: String) -> [String] {
        switch self {
        case .object(let object):
            var values: [String] = []
            if case .string(let value)? = object[key] { values.append(value) }
            for value in object.values { values.append(contentsOf: value.recursiveStrings(for: key)) }
            return Array(Set(values))
        case .array(let values):
            return Array(Set(values.flatMap { $0.recursiveStrings(for: key) }))
        default:
            return []
        }
    }

    func humanReadableSummary(maxLength: Int) -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "Review the request details in Codex." }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
