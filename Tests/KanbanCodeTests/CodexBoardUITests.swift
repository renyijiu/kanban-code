import Foundation
import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Codex Board UI")
struct CodexBoardUITests {
    @Test("Codex thread deep links encode the complete thread identifier")
    func deepLinkEncoding() {
        let url = CodexSessionNavigation.codexThreadURL(threadId: "thread with/slash")

        #expect(url?.absoluteString == "codex://threads/thread%20with%2Fslash")
    }

    @Test("App execution binding takes the user to the exact Codex thread")
    func appDestination() {
        let link = Link(
            id: "app-card",
            column: .waiting,
            executionBinding: CodexExecutionBinding(
                backend: .app,
                ownership: .observed,
                evidence: .appServerSource,
                telemetryQuality: .precise,
                threadId: "019f-thread"
            ),
            assistant: .codex
        )

        #expect(
            CodexSessionNavigation.destination(
                executionBinding: link.executionBinding,
                legacyTmuxSessionName: link.tmuxLink?.sessionName
            )
                == .codexThread(URL(string: "codex://threads/019f-thread")!)
        )
    }

    @Test("CLI execution binding locates tmux even without the legacy tmux link")
    func cliDestination() {
        let link = Link(
            id: "cli-card",
            column: .inProgress,
            executionBinding: CodexExecutionBinding(
                backend: .cliTmux,
                ownership: .managed,
                evidence: .boardCreated,
                telemetryQuality: .precise,
                tmuxSessionName: "kanban-code-cli-card-1"
            ),
            assistant: .codex
        )

        #expect(
            CodexSessionNavigation.destination(
                executionBinding: link.executionBinding,
                legacyTmuxSessionName: link.tmuxLink?.sessionName
            )
                == .tmux("kanban-code-cli-card-1")
        )
    }

    @Test("Legacy sessions without a runtime binding remain openable as details")
    func legacyDestination() {
        let link = Link(
            id: "legacy-card",
            column: .allSessions,
            sessionLink: SessionLink(sessionId: "legacy-session")
        )

        #expect(
            CodexSessionNavigation.destination(
                executionBinding: link.executionBinding,
                legacyTmuxSessionName: link.tmuxLink?.sessionName
            ) == .details
        )
    }
}
