import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex App Server process transport")
struct CodexAppServerProcessTransportTests {
    @Test("Project-local executables are rejected after path normalization")
    func projectLocalExecutable() {
        let root = URL(fileURLWithPath: "/tmp/example-project")
        #expect(CodexExecutableResolver.isProjectLocal(
            executable: root.appendingPathComponent("node_modules/.bin/codex"),
            projectRoot: root
        ))
        #expect(!CodexExecutableResolver.isProjectLocal(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            projectRoot: root
        ))
    }

    @Test("Line transport separates concurrent reads and writes")
    func lineTransportRoundTrip() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        let transport = try CodexAppServerProcessTransport.launch(
            executable: executable,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        // `env app-server` exits because there is no such executable. The
        // transport must report EOF cleanly rather than hanging a reader.
        let line = try await transport.readLine()
        #expect(line == nil)
    }
}
