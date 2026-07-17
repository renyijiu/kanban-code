import Foundation

/// Canonical lifecycle inputs produced by App Server and hook adapters.
/// Adapters normalize their wire payloads before the board sees them.
public enum CodexLifecycleEventKind: String, Codable, Sendable, CaseIterable {
    case queued
    case launchStarted
    case running
    case waitingForInput
    case waitingForApproval
    case stopped
    case faulted
    case disconnected
    case reviewReady
    case accepted

    fileprivate var semanticPrecedence: Int {
        switch self {
        case .queued: 0
        case .launchStarted: 10
        case .running: 20
        case .stopped: 30
        case .disconnected: 35
        case .waitingForInput: 40
        case .waitingForApproval: 50
        case .faulted: 60
        case .reviewReady: 70
        case .accepted: 80
        }
    }
}

public struct CodexLifecycleEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let cardId: String
    public let kind: CodexLifecycleEventKind
    public let watermark: LifecycleEventWatermark
    public let telemetryQuality: TelemetryQuality

    public init(
        id: String,
        cardId: String,
        kind: CodexLifecycleEventKind,
        watermark: LifecycleEventWatermark,
        telemetryQuality: TelemetryQuality = .precise
    ) {
        self.id = id
        self.cardId = cardId
        self.kind = kind
        self.watermark = watermark
        self.telemetryQuality = telemetryQuality
    }
}

public enum CodexLifecycleReduction: Sendable, Equatable {
    case applied(CardRuntimeState)
    case duplicate(CardRuntimeState)
    case ignoredStale(CardRuntimeState)
    case conflicted(CardRuntimeState)
}

/// Deterministic reducer for lifecycle signals. It intentionally compares
/// launch generation and turn identity before timestamps: arrival order is not
/// authority when App Server reconnects or hook files are drained in batches.
public enum CodexLifecycleReducer {
    public static func reduce(
        current: CardRuntimeState?,
        event: CodexLifecycleEvent,
        now: Date = .now
    ) -> CodexLifecycleReduction {
        var state = current ?? CardRuntimeState(cardId: event.cardId)
        guard state.cardId == event.cardId else { return .ignoredStale(state) }

        if state.lifecycle.watermark?.eventId == event.id {
            return .duplicate(state)
        }

        if let existing = state.lifecycle.watermark {
            switch compare(event: event, to: existing, currentPhase: state.lifecycle.phase) {
            case .older:
                return .ignoredStale(state)
            case .incomparable:
                // Do not let an incomparable source clear a precise state. Mark
                // the projection limited so the UI never overclaims certainty.
                state.lifecycle.telemetryQuality = .limited
                state.updatedAt = now
                return .conflicted(state)
            case .same, .newer:
                break
            }
        }

        if let correction = state.lifecycle.manualCorrection {
            if let correctionWatermark = correction.watermark,
               compare(event: event, to: correctionWatermark, currentPhase: correction.phase) != .newer {
                return .ignoredStale(state)
            }
            state.lifecycle.manualCorrection = nil
        }

        let projection = lifecycle(for: event.kind)
        state.lifecycle.phase = projection.phase
        state.lifecycle.waitReason = projection.reason
        state.lifecycle.telemetryQuality = event.telemetryQuality
        state.lifecycle.watermark = event.watermark
        state.updatedAt = now
        return .applied(state)
    }

    private enum Order { case older, same, newer, incomparable }

    private static func compare(
        event: CodexLifecycleEvent,
        to existing: LifecycleEventWatermark,
        currentPhase: LifecyclePhase
    ) -> Order {
        if event.id == existing.eventId { return .same }

        if let incomingGeneration = event.watermark.generation,
           let existingGeneration = existing.generation,
           incomingGeneration != existingGeneration {
            return incomingGeneration > existingGeneration ? .newer : .older
        }

        // Explicit, acknowledgement-backed human actions are authoritative
        // within the same launch generation even when the helper that entered
        // review did not know the App Server turn identifier.
        if event.kind == .accepted, event.watermark.source == "board:accept" {
            return .newer
        }
        if event.kind == .reviewReady, event.watermark.source == "board:manual-review" {
            return .newer
        }
        if event.kind == .running,
           (event.watermark.source == "board:continue" || event.watermark.source == "board:response") {
            return .newer
        }

        // A structured review-ready signal is authoritative for the current
        // launch. Codex normally emits Stop immediately afterwards; that Stop
        // describes the same completed work and must not move the card back to
        // Waiting.
        if currentPhase == .inReview, event.kind == .stopped {
            return .older
        }

        if let incomingTurn = event.watermark.turnId,
           let existingTurn = existing.turnId {
            if incomingTurn != existingTurn {
                // Different turns are ordered only by an explicit sequence or
                // trusted occurrence time. Otherwise neither source can erase
                // the other.
                if let incomingSequence = event.watermark.sequence,
                   let existingSequence = existing.sequence,
                   incomingSequence != existingSequence {
                    return incomingSequence > existingSequence ? .newer : .older
                }
                if event.watermark.occurredAt != existing.occurredAt {
                    return event.watermark.occurredAt > existing.occurredAt ? .newer : .older
                }
                return .incomparable
            }

            if let incomingSequence = event.watermark.sequence,
               let existingSequence = existing.sequence,
               incomingSequence != existingSequence {
                return incomingSequence > existingSequence ? .newer : .older
            }


            // Approval and input requests suspend a turn rather than ending
            // it. A later running signal for that same turn resumes it.
            if currentPhase == .waiting,
               event.kind == .running,
               event.watermark.occurredAt > existing.occurredAt {
                return .newer
            }
            let currentPrecedence = semanticPrecedence(for: currentPhase)
            if event.kind.semanticPrecedence != currentPrecedence {
                return event.kind.semanticPrecedence > currentPrecedence ? .newer : .older
            }
        }

        if event.watermark.source == existing.source {
            if event.watermark.occurredAt != existing.occurredAt {
                return event.watermark.occurredAt > existing.occurredAt ? .newer : .older
            }
            return .newer
        }
        return .incomparable
    }

    private static func semanticPrecedence(for phase: LifecyclePhase) -> Int {
        switch phase {
        case .queued: 0
        case .launching: 10
        case .running: 20
        case .waiting: 30
        case .inReview: 70
        case .done: 80
        case .unknown: -1
        }
    }

    private static func lifecycle(
        for kind: CodexLifecycleEventKind
    ) -> (phase: LifecyclePhase, reason: LifecycleWaitReason?) {
        switch kind {
        case .queued: (.queued, nil)
        case .launchStarted: (.launching, nil)
        case .running: (.running, nil)
        case .waitingForInput: (.waiting, .input)
        case .waitingForApproval: (.waiting, .approval)
        case .stopped: (.waiting, .ordinaryStop)
        case .faulted: (.waiting, .fault)
        case .disconnected: (.waiting, .disconnected)
        case .reviewReady: (.inReview, nil)
        case .accepted: (.done, nil)
        }
    }
}

public enum AttentionPrimaryAction: String, Sendable, Equatable {
    case respond
    case approve
    case retry
    case inspect
}

public struct AttentionItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let cardId: String
    public let title: String
    public let runtime: CodexRuntimeBackend
    public let project: String?
    public let reason: LifecycleWaitReason
    public let age: TimeInterval
    public let telemetryQuality: TelemetryQuality
    public let primaryAction: AttentionPrimaryAction
    public let canOpenSession: Bool

    fileprivate var priority: Int {
        switch reason {
        case .approval: 0
        case .input: 1
        case .fault: 2
        case .launchUncertain: 3
        case .ordinaryStop: 4
        case .disconnected: 5
        case .unknown: 6
        }
    }
}

/// Pure projections used by both SwiftUI and tests. All Sessions is deliberately
/// not returned as a board lane; it remains a separate search/archive surface.
public enum CodexBoardProjection {
    public static let lanes: [KanbanCodeColumn] = [
        .backlog, .inProgress, .waiting, .inReview, .done,
    ]

    public static func column(
        for link: Link,
        runtimeState: CardRuntimeState?,
        legacyActivity: ActivityState? = nil,
        hasLiveWork: Bool = false
    ) -> KanbanCodeColumn {
        if link.manuallyArchived { return .allSessions }

        // Completion is intentionally strict: closed-but-unmerged is not done,
        // and every linked PR must be merged.
        if link.allPRsDone {
            return .done
        }

        let lifecycle = runtimeState?.lifecycle
        let phase = lifecycle?.manualCorrection?.phase ?? lifecycle?.phase
        switch phase {
        case .queued: return .backlog
        case .launching, .running: return .inProgress
        case .waiting: return .waiting
        case .inReview: return .inReview
        case .done: return .done
        case .unknown, nil:
            return AssignColumn.assign(
                link: link,
                activityState: legacyActivity,
                // A PR is optional evidence, never a Codex lifecycle state.
                // Only the strict all-merged check above can affect the lane.
                hasPR: false,
                allPRsDone: false,
                hasWorktree: hasLiveWork
            )
        }
    }

    public static func matchesBoardRuntime(_ link: Link, runtime: CodexRuntimeBackend) -> Bool {
        guard link.effectiveAssistant == .codex else { return false }
        return link.executionBinding?.backend == runtime
    }

    public static func attentionItems(
        links: [String: Link],
        runtimeStates: [String: CardRuntimeState],
        now: Date = .now
    ) -> [AttentionItem] {
        runtimeStates.values.compactMap { state -> AttentionItem? in
            guard let link = links[state.cardId], !link.manuallyArchived,
                  state.lifecycle.phase == .waiting,
                  let reason = state.lifecycle.waitReason,
                  reason != .unknown
            else { return nil }

            let action: AttentionPrimaryAction = switch reason {
            case .approval: .approve
            case .input: .respond
            case .launchUncertain: .retry
            case .ordinaryStop, .fault, .disconnected, .unknown: .inspect
            }
            return AttentionItem(
                id: "\(state.cardId):\(reason.rawValue)",
                cardId: state.cardId,
                title: link.displayTitle,
                runtime: link.executionBinding?.backend ?? .unknown,
                project: link.projectPath.map { ($0 as NSString).lastPathComponent },
                reason: reason,
                age: max(0, now.timeIntervalSince(state.updatedAt)),
                telemetryQuality: state.lifecycle.telemetryQuality,
                primaryAction: action,
                canOpenSession: link.executionBinding?.threadId != nil
                    || link.executionBinding?.tmuxSessionName != nil
                    || link.tmuxLink != nil
            )
        }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.age != $1.age { return $0.age > $1.age }
            return $0.cardId < $1.cardId
        }
    }
}
