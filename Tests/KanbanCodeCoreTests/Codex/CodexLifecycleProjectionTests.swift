import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex lifecycle and board projection")
struct CodexLifecycleProjectionTests {
    private func event(
        _ kind: CodexLifecycleEventKind,
        id: String,
        cardId: String = "card-1",
        source: String = "app-server",
        generation: Int = 1,
        turn: String = "turn-1",
        sequence: Int
    ) -> CodexLifecycleEvent {
        CodexLifecycleEvent(
            id: id,
            cardId: cardId,
            kind: kind,
            watermark: LifecycleEventWatermark(
                eventId: id,
                source: source,
                generation: generation,
                turnId: turn,
                sequence: sequence,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence))
            )
        )
    }

    @Test("Duplicate and stale events cannot rewind lifecycle")
    func duplicateAndStaleEvents() {
        let running = event(.running, id: "running", sequence: 2)
        guard case .applied(let state) = CodexLifecycleReducer.reduce(current: nil, event: running) else {
            Issue.record("running event should apply")
            return
        }

        #expect(CodexLifecycleReducer.reduce(current: state, event: running) == .duplicate(state))
        let stale = event(.queued, id: "queued", sequence: 1)
        #expect(CodexLifecycleReducer.reduce(current: state, event: stale) == .ignoredStale(state))
    }

    @Test("Review-ready outranks a duplicated ordinary stop in the same turn")
    func reviewReadyOutranksStop() {
        let review = event(.reviewReady, id: "review", sequence: 8)
        guard case .applied(let state) = CodexLifecycleReducer.reduce(current: nil, event: review) else {
            Issue.record("review event should apply")
            return
        }
        let delayedStop = event(.stopped, id: "stop", sequence: 7)
        #expect(CodexLifecycleReducer.reduce(current: state, event: delayedStop) == .ignoredStale(state))
        #expect(state.lifecycle.phase == .inReview)
    }

    @Test("A later Stop cannot erase review-ready even without turn provenance")
    func reviewReadySurvivesLaterStop() {
        let review = CodexLifecycleEvent(
            id: "review",
            cardId: "card-1",
            kind: .reviewReady,
            watermark: .init(
                eventId: "review",
                source: "codex-lifecycle-inbox",
                generation: 1,
                occurredAt: Date(timeIntervalSince1970: 10)
            )
        )
        guard case .applied(let state) = CodexLifecycleReducer.reduce(current: nil, event: review) else {
            Issue.record("review event should apply")
            return
        }
        let stop = CodexLifecycleEvent(
            id: "stop",
            cardId: "card-1",
            kind: .stopped,
            watermark: .init(
                eventId: "stop",
                source: "codex-lifecycle-inbox",
                generation: 1,
                turnId: "turn-1",
                occurredAt: Date(timeIntervalSince1970: 11)
            )
        )
        #expect(CodexLifecycleReducer.reduce(current: state, event: stop) == .ignoredStale(state))
    }

    @Test("A later running event resumes the same waiting turn")
    func waitingTurnResumes() {
        let waiting = event(.waitingForApproval, id: "approval", sequence: 4)
        guard case .applied(let state) = CodexLifecycleReducer.reduce(current: nil, event: waiting) else {
            Issue.record("approval event should apply")
            return
        }
        let resumed = event(.running, id: "resumed", sequence: 5)
        guard case .applied(let result) = CodexLifecycleReducer.reduce(current: state, event: resumed) else {
            Issue.record("later running event should resume the turn")
            return
        }
        #expect(result.lifecycle.phase == .running)
    }

    @Test("Acknowledged review feedback resumes the original turn")
    func reviewFeedbackResumes() {
        let review = CodexLifecycleEvent(
            id: "review",
            cardId: "card-1",
            kind: .reviewReady,
            watermark: .init(
                eventId: "review",
                source: "helper",
                generation: 1,
                occurredAt: Date(timeIntervalSince1970: 5)
            )
        )
        let current = CodexLifecycleReducer.reduce(current: nil, event: review).projectedState
        let continued = CodexLifecycleEvent(
            id: "continued",
            cardId: "card-1",
            kind: .running,
            watermark: .init(
                eventId: "continued",
                source: "board:continue",
                generation: 1,
                turnId: "turn-1",
                occurredAt: review.watermark.occurredAt.addingTimeInterval(1)
            )
        )
        #expect(CodexLifecycleReducer.reduce(current: current, event: continued).projectedState.lifecycle.phase == .running)
    }

    @Test("Human acceptance completes review even when helper had no turn id")
    func reviewAcceptanceCompletes() {
        let review = CodexLifecycleEvent(
            id: "review",
            cardId: "card-1",
            kind: .reviewReady,
            watermark: .init(eventId: "review", source: "helper", generation: 1, occurredAt: .now)
        )
        let current = CodexLifecycleReducer.reduce(current: nil, event: review).projectedState
        let accepted = CodexLifecycleEvent(
            id: "accepted",
            cardId: "card-1",
            kind: .accepted,
            watermark: .init(eventId: "accepted", source: "board:accept", generation: 1, turnId: "turn-1", occurredAt: .now)
        )
        #expect(CodexLifecycleReducer.reduce(current: current, event: accepted).projectedState.lifecycle.phase == .done)
    }

    @Test("A manual review action is authoritative for a running task")
    func manualReviewReady() {
        let running = event(.running, id: "running", source: "app-server", sequence: 3)
        let current = CodexLifecycleReducer.reduce(current: nil, event: running).projectedState
        let review = CodexLifecycleEvent(
            id: "manual-review",
            cardId: "card-1",
            kind: .reviewReady,
            watermark: .init(
                eventId: "manual-review",
                source: "board:manual-review",
                generation: 1,
                occurredAt: Date(timeIntervalSince1970: 4)
            )
        )
        #expect(CodexLifecycleReducer.reduce(current: current, event: review).projectedState.lifecycle.phase == .inReview)
    }

    @Test("Incomparable sources retain the precise state and mark telemetry limited")
    func incomparableSources() {
        let running = event(.running, id: "running", source: "app-server", sequence: 2)
        guard case .applied(let state) = CodexLifecycleReducer.reduce(current: nil, event: running) else {
            Issue.record("running event should apply")
            return
        }
        var hook = event(.stopped, id: "hook-stop", source: "hook", sequence: 2)
        hook = CodexLifecycleEvent(
            id: hook.id,
            cardId: hook.cardId,
            kind: hook.kind,
            watermark: LifecycleEventWatermark(
                eventId: hook.id,
                source: "hook",
                generation: nil,
                turnId: nil,
                sequence: nil,
                occurredAt: state.updatedAt
            ),
            telemetryQuality: .limited
        )
        guard case .conflicted(let conflicted) = CodexLifecycleReducer.reduce(current: state, event: hook) else {
            Issue.record("incomparable event should conflict")
            return
        }
        #expect(conflicted.lifecycle.phase == .running)
        #expect(conflicted.lifecycle.telemetryQuality == .limited)
    }

    @Test("Only all-merged PRs auto-complete")
    func strictPRCompletion() {
        var link = Link(id: "card-1", source: .manual)
        link.prLinks = [PRLink(number: 1, status: .closed)]
        #expect(CodexBoardProjection.column(for: link, runtimeState: nil) != .done)

        link.prLinks = [PRLink(number: 1, status: .merged)]
        #expect(CodexBoardProjection.column(for: link, runtimeState: nil) == .done)

        link.prLinks.append(PRLink(number: 2, status: .reviewNeeded))
        #expect(CodexBoardProjection.column(for: link, runtimeState: nil) != .done)
    }

    @Test("A stopped Codex task with an open PR stays Waiting")
    func stoppedWithPROnlyWaits() {
        var link = Link(id: "card-1", source: .manual, assistant: .codex)
        link.prLinks = [PRLink(number: 1, status: .reviewNeeded)]
        let state = CardRuntimeState(
            cardId: link.id,
            lifecycle: LifecycleSnapshot(
                phase: .waiting,
                waitReason: .ordinaryStop,
                telemetryQuality: .precise
            )
        )
        #expect(CodexBoardProjection.column(for: link, runtimeState: state) == .waiting)
    }

    @Test("Attention is global but includes only actionable waiting states")
    func globalAttentionProjection() {
        var appLink = Link(id: "app", name: "Approve App", projectPath: "/tmp/app", source: .manual, assistant: .codex)
        appLink.executionBinding = CodexExecutionBinding(
            backend: .app,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .precise,
            threadId: "thread-1"
        )
        var cliLink = Link(id: "cli", name: "Running CLI", source: .manual, assistant: .codex)
        cliLink.executionBinding = CodexExecutionBinding(
            backend: .cliTmux,
            ownership: .managed,
            evidence: .tmuxBinding,
            telemetryQuality: .precise,
            tmuxSessionName: "codex-cli"
        )
        let states = [
            "app": CardRuntimeState(cardId: "app", lifecycle: LifecycleSnapshot(phase: .waiting, waitReason: .approval, telemetryQuality: .precise)),
            "cli": CardRuntimeState(cardId: "cli", lifecycle: LifecycleSnapshot(phase: .running, telemetryQuality: .precise)),
        ]
        let attention = CodexBoardProjection.attentionItems(
            links: ["app": appLink, "cli": cliLink],
            runtimeStates: states
        )
        #expect(attention.map(\.cardId) == ["app"])
        #expect(attention.first?.primaryAction == .approve)
        #expect(CodexBoardProjection.matchesBoardRuntime(appLink, runtime: .cliTmux) == false)
        #expect(CodexBoardProjection.matchesBoardRuntime(cliLink, runtime: .cliTmux))
    }

    @Test("The board exposes exactly five workflow lanes")
    func fiveLanes() {
        #expect(CodexBoardProjection.lanes == [.backlog, .inProgress, .waiting, .inReview, .done])
        #expect(!CodexBoardProjection.lanes.contains(.allSessions))
    }
}

private extension CodexLifecycleReduction {
    var projectedState: CardRuntimeState {
        switch self {
        case .applied(let state), .duplicate(let state), .ignoredStale(let state), .conflicted(let state):
            state
        }
    }
}
