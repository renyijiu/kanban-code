import Foundation

/// The execution environment that owns a Codex task. This is deliberately
/// separate from `CodingAssistant`: Codex is the assistant in both modes.
public enum CodexRuntimeBackend: String, Codable, Sendable, CaseIterable {
    case app
    case cliTmux
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public enum RuntimeOwnership: String, Codable, Sendable, CaseIterable {
    case managed
    case observed

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .observed
    }
}

public enum RuntimeEvidence: String, Codable, Sendable, CaseIterable {
    case userConfirmed
    case boardCreated
    case tmuxBinding
    case appServerSource
    case cliMetadata
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Higher-authority evidence must not be silently replaced by discovery.
    public var authority: Int {
        switch self {
        case .userConfirmed: 5
        case .boardCreated: 4
        case .tmuxBinding: 3
        case .appServerSource: 2
        case .cliMetadata: 1
        case .unknown: 0
        }
    }
}

public enum TelemetryQuality: String, Codable, Sendable, CaseIterable {
    case precise
    case limited
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

/// Discovery-time evidence about where a session originated.
public struct CodexRuntimeProvenance: Codable, Sendable, Equatable {
    public var backend: CodexRuntimeBackend
    public var ownership: RuntimeOwnership
    public var evidence: RuntimeEvidence
    public var telemetryQuality: TelemetryQuality
    public var observedAt: Date?

    public init(
        backend: CodexRuntimeBackend,
        ownership: RuntimeOwnership = .observed,
        evidence: RuntimeEvidence = .unknown,
        telemetryQuality: TelemetryQuality = .unknown,
        observedAt: Date? = nil
    ) {
        self.backend = backend
        self.ownership = ownership
        self.evidence = evidence
        self.telemetryQuality = telemetryQuality
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case backend, ownership, evidence, telemetryQuality, observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = (try? container.decode(CodexRuntimeBackend.self, forKey: .backend)) ?? .unknown
        ownership = (try? container.decode(RuntimeOwnership.self, forKey: .ownership)) ?? .observed
        evidence = (try? container.decode(RuntimeEvidence.self, forKey: .evidence)) ?? .unknown
        telemetryQuality = (try? container.decode(TelemetryQuality.self, forKey: .telemetryQuality)) ?? .unknown
        observedAt = try? container.decodeIfPresent(Date.self, forKey: .observedAt)
    }

    /// Resolves competing discovery evidence without allowing a weaker signal
    /// to flip a user-confirmed or board-created backend.
    public func preferring(_ candidate: Self) -> Self {
        if candidate.evidence.authority != evidence.authority {
            return candidate.evidence.authority > evidence.authority ? candidate : self
        }
        switch (observedAt, candidate.observedAt) {
        case let (current?, proposed?) where proposed > current:
            return candidate
        case (nil, .some):
            return candidate
        default:
            return self
        }
    }
}

/// Stable identifiers needed to return to the exact runtime session.
public struct CodexExecutionBinding: Codable, Sendable, Equatable {
    public var backend: CodexRuntimeBackend
    public var ownership: RuntimeOwnership
    public var evidence: RuntimeEvidence
    public var telemetryQuality: TelemetryQuality
    public var threadId: String?
    public var turnId: String?
    public var sessionId: String?
    public var tmuxSessionName: String?
    public var boundAt: Date?

    public init(
        backend: CodexRuntimeBackend,
        ownership: RuntimeOwnership,
        evidence: RuntimeEvidence,
        telemetryQuality: TelemetryQuality,
        threadId: String? = nil,
        turnId: String? = nil,
        sessionId: String? = nil,
        tmuxSessionName: String? = nil,
        boundAt: Date? = nil
    ) {
        self.backend = backend
        self.ownership = ownership
        self.evidence = evidence
        self.telemetryQuality = telemetryQuality
        self.threadId = threadId
        self.turnId = turnId
        self.sessionId = sessionId
        self.tmuxSessionName = tmuxSessionName
        self.boundAt = boundAt
    }
}

public enum LifecyclePhase: String, Codable, Sendable, CaseIterable {
    case queued
    case launching
    case running
    case waiting
    case inReview
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public enum LifecycleWaitReason: String, Codable, Sendable, CaseIterable {
    case input
    case approval
    case ordinaryStop
    case fault
    case disconnected
    case launchUncertain
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

/// Source identity and partial-order metadata for a normalized lifecycle event.
public struct LifecycleEventWatermark: Codable, Sendable, Equatable {
    public var eventId: String
    public var source: String
    public var generation: Int?
    public var turnId: String?
    public var sequence: Int?
    public var occurredAt: Date

    public init(
        eventId: String,
        source: String,
        generation: Int? = nil,
        turnId: String? = nil,
        sequence: Int? = nil,
        occurredAt: Date = .now
    ) {
        self.eventId = eventId
        self.source = source
        self.generation = generation
        self.turnId = turnId
        self.sequence = sequence
        self.occurredAt = occurredAt
    }
}

public struct LifecycleManualCorrection: Codable, Sendable, Equatable {
    public var phase: LifecyclePhase
    public var watermark: LifecycleEventWatermark?
    public var correctedAt: Date

    public init(
        phase: LifecyclePhase,
        watermark: LifecycleEventWatermark? = nil,
        correctedAt: Date = .now
    ) {
        self.phase = phase
        self.watermark = watermark
        self.correctedAt = correctedAt
    }
}

public struct LifecycleSnapshot: Codable, Sendable, Equatable {
    public var phase: LifecyclePhase
    public var waitReason: LifecycleWaitReason?
    public var telemetryQuality: TelemetryQuality
    public var watermark: LifecycleEventWatermark?
    public var manualCorrection: LifecycleManualCorrection?

    public init(
        phase: LifecyclePhase = .unknown,
        waitReason: LifecycleWaitReason? = nil,
        telemetryQuality: TelemetryQuality = .unknown,
        watermark: LifecycleEventWatermark? = nil,
        manualCorrection: LifecycleManualCorrection? = nil
    ) {
        self.phase = phase
        self.waitReason = waitReason
        self.telemetryQuality = telemetryQuality
        self.watermark = watermark
        self.manualCorrection = manualCorrection
    }
}

/// Durable claim written before a runtime launch side effect begins.
public struct LaunchLease: Codable, Sendable, Equatable {
    public var attemptId: String
    public var backend: CodexRuntimeBackend
    public var generation: Int
    public var lifecycleCapability: String?
    public var acquiredAt: Date
    public var expiresAt: Date?

    public init(
        attemptId: String,
        backend: CodexRuntimeBackend,
        generation: Int,
        lifecycleCapability: String? = nil,
        acquiredAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.attemptId = attemptId
        self.backend = backend
        self.generation = generation
        self.lifecycleCapability = lifecycleCapability
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}

/// Swift-owned runtime state. Kept out of `links.json` so lifecycle writes do
/// not churn the cross-platform card file.
public struct CardRuntimeState: Codable, Sendable, Equatable, Identifiable {
    public var cardId: String
    public var lifecycle: LifecycleSnapshot
    public var launchLease: LaunchLease?
    public var executionBinding: CodexExecutionBinding?
    public var updatedAt: Date

    public var id: String { cardId }

    public init(
        cardId: String,
        lifecycle: LifecycleSnapshot = LifecycleSnapshot(),
        launchLease: LaunchLease? = nil,
        executionBinding: CodexExecutionBinding? = nil,
        updatedAt: Date = .now
    ) {
        self.cardId = cardId
        self.lifecycle = lifecycle
        self.launchLease = launchLease
        self.executionBinding = executionBinding
        self.updatedAt = updatedAt
    }
}
