import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Codex App Server session discovery")
struct CodexAppServerSessionDiscoveryTests {
    @Test("Source kinds classify app and CLI evidence without guessing conflicts")
    func sourceClassification() {
        let app = CodexAppServerSessionDiscovery.provenance(sourceKinds: ["desktopApp"])
        #expect(app.backend == .app)
        #expect(app.telemetryQuality == .precise)

        let cli = CodexAppServerSessionDiscovery.provenance(sourceKinds: ["cli"])
        #expect(cli.backend == .cliTmux)

        let conflict = CodexAppServerSessionDiscovery.provenance(sourceKinds: ["app", "cli"])
        #expect(conflict.backend == .unknown)
        #expect(conflict.telemetryQuality == .limited)

        let absent = CodexAppServerSessionDiscovery.provenance(sourceKinds: [])
        #expect(absent.backend == .unknown)
    }

    @Test("Structured thread status maps existing App sessions into active and waiting lifecycle")
    func statusProjection() throws {
        let waiting = try JSONDecoder().decode(CodexThread.self, from: Data(#"{"id":"one","status":{"type":"active","activeFlags":["waitingOnApproval"]}}"#.utf8))
        let running = try JSONDecoder().decode(CodexThread.self, from: Data(#"{"id":"two","status":{"type":"active"}}"#.utf8))
        let historical = try JSONDecoder().decode(CodexThread.self, from: Data(#"{"id":"three","status":{"type":"idle"}}"#.utf8))

        #expect(CodexAppServerSessionDiscovery.lifecycle(status: waiting.status).waitReason == .approval)
        #expect(CodexAppServerSessionDiscovery.lifecycle(status: running.status).phase == .running)
        #expect(CodexAppServerSessionDiscovery.lifecycle(status: historical.status).phase == .unknown)
    }
}
