import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex runtime domain")
struct CodexRuntimeDomainTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @Test("Legacy Link decodes without an execution binding")
    func legacyLinkDecodes() throws {
        let json = """
        {
          "id": "card-legacy",
          "column": "backlog",
          "manualOverrides": {},
          "manuallyArchived": false,
          "source": "manual",
          "isRemote": false
        }
        """

        let link = try decoder.decode(Link.self, from: Data(json.utf8))

        #expect(link.executionBinding == nil)
    }

    @Test("Codex execution binding round-trips on Link")
    func executionBindingRoundTrip() throws {
        let binding = CodexExecutionBinding(
            backend: .app,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .precise,
            threadId: "thread-123",
            sessionId: "session-123"
        )
        let link = Link(id: "card-runtime", executionBinding: binding, assistant: .codex)

        let decoded = try decoder.decode(Link.self, from: encoder.encode(link))

        #expect(decoded.executionBinding == binding)
    }

    @Test("Unknown runtime enum values degrade safely")
    func unknownRuntimeValuesDegradeSafely() throws {
        let json = """
        {
          "backend": "futureBackend",
          "ownership": "futureOwnership",
          "evidence": "futureEvidence",
          "telemetryQuality": "futureQuality"
        }
        """

        let provenance = try decoder.decode(CodexRuntimeProvenance.self, from: Data(json.utf8))

        #expect(provenance.backend == .unknown)
        #expect(provenance.ownership == .observed)
        #expect(provenance.evidence == .unknown)
        #expect(provenance.telemetryQuality == .unknown)
    }

    @Test("User-confirmed provenance outranks conflicting discovery")
    func provenanceAuthority() {
        let confirmed = CodexRuntimeProvenance(
            backend: .app,
            ownership: .observed,
            evidence: .userConfirmed,
            telemetryQuality: .precise,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let discovered = CodexRuntimeProvenance(
            backend: .cliTmux,
            ownership: .observed,
            evidence: .tmuxBinding,
            telemetryQuality: .limited,
            observedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(confirmed.preferring(discovered).backend == .app)
        #expect(discovered.preferring(confirmed).backend == .app)
    }

    @Test("Session provenance is optional and Codable")
    func sessionProvenanceCodable() throws {
        let legacyJSON = """
        {
          "id": "legacy-session",
          "messageCount": 2,
          "modifiedTime": "2026-07-18T00:00:00Z",
          "assistant": "codex"
        }
        """
        let legacy = try decoder.decode(Session.self, from: Data(legacyJSON.utf8))
        #expect(legacy.runtimeProvenance == nil)

        let provenance = CodexRuntimeProvenance(
            backend: .cliTmux,
            ownership: .observed,
            evidence: .tmuxBinding,
            telemetryQuality: .limited
        )
        let session = Session(id: "session-1", assistant: .codex, runtimeProvenance: provenance)
        let decoded = try decoder.decode(Session.self, from: encoder.encode(session))
        #expect(decoded.runtimeProvenance == provenance)
    }

    @Test("Lifecycle state captures manual correction and launch lease")
    func lifecycleStateRoundTrip() throws {
        let watermark = LifecycleEventWatermark(
            eventId: "event-1",
            source: "hook",
            generation: 4,
            turnId: "turn-2",
            sequence: 7,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let correction = LifecycleManualCorrection(
            phase: .inReview,
            watermark: watermark,
            correctedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let lease = LaunchLease(
            attemptId: "attempt-1",
            backend: .app,
            generation: 4,
            acquiredAt: Date(timeIntervalSince1970: 1_700_000_200),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let state = CardRuntimeState(
            cardId: "card-1",
            lifecycle: LifecycleSnapshot(
                phase: .inReview,
                waitReason: nil,
                telemetryQuality: .precise,
                watermark: watermark,
                manualCorrection: correction
            ),
            launchLease: lease,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        let decoded = try decoder.decode(CardRuntimeState.self, from: encoder.encode(state))

        #expect(decoded == state)
    }
}
