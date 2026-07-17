import Foundation

public struct CodexTmuxOwnershipTag: Codable, Sendable, Equatable {
    public var cardId: String
    public var attemptId: String
    public var generation: Int

    public init(cardId: String, attemptId: String, generation: Int) {
        self.cardId = cardId
        self.attemptId = attemptId
        self.generation = generation
    }
}

/// Stores ownership on the tmux session itself. A reserved name alone is not
/// sufficient evidence because a user-created session could collide with it.
public protocol CodexTmuxMetadataPort: Sendable {
    func ownershipTag(for sessionName: String) async throws -> CodexTmuxOwnershipTag?
    func setOwnershipTag(_ tag: CodexTmuxOwnershipTag, for sessionName: String) async throws
}

public final class CodexTmuxMetadataAdapter: CodexTmuxMetadataPort, @unchecked Sendable {
    private static let optionName = "@kanban-code-owner"
    private let tmuxPath: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? ShellCommand.findExecutable("tmux") ?? "tmux"
    }

    public func ownershipTag(for sessionName: String) async throws -> CodexTmuxOwnershipTag? {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["show-options", "-v", "-t", sessionName, Self.optionName]
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return try decoder.decode(CodexTmuxOwnershipTag.self, from: data)
    }

    public func setOwnershipTag(_ tag: CodexTmuxOwnershipTag, for sessionName: String) async throws {
        let data = try encoder.encode(tag)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexRuntimeError.launchUncertain("Could not encode tmux ownership metadata")
        }
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["set-option", "-t", sessionName, Self.optionName, value]
        )
        guard result.succeeded else {
            throw CodexRuntimeError.launchUncertain(
                "tmux session was created, but its ownership tag could not be persisted: \(result.stderr)"
            )
        }
    }
}

/// Codex CLI implementation of the managed runtime contract. It uses a
/// deterministic, reserved tmux namespace and never kills an uncertain session.
public final class CodexCLITmuxRuntime: CodexRuntimePort, @unchecked Sendable {
    public let backend: CodexRuntimeBackend = .cliTmux

    private let tmux: any TmuxManagerPort
    private let metadata: any CodexTmuxMetadataPort
    private let codexExecutablePath: String

    public init(
        tmux: any TmuxManagerPort,
        metadata: any CodexTmuxMetadataPort,
        codexExecutablePath: String? = nil
    ) {
        self.tmux = tmux
        self.metadata = metadata
        self.codexExecutablePath = codexExecutablePath
            ?? ShellCommand.findExecutable("codex")
            ?? "codex"
    }

    public func launch(_ request: CodexRuntimeLaunchRequest) async throws -> CodexRuntimeLaunchReceipt {
        guard await tmux.isAvailable() else {
            throw CodexRuntimeError.unavailable("tmux is not available")
        }

        let sessionName = Self.sessionName(cardId: request.cardId, generation: request.generation)
        let expectedTag = CodexTmuxOwnershipTag(
            cardId: request.cardId,
            attemptId: request.attemptId,
            generation: request.generation
        )
        let sessions: [TmuxSession]
        do {
            sessions = try await tmux.listSessions()
        } catch {
            throw CodexRuntimeError.notStarted("Could not inspect tmux before launch: \(error.localizedDescription)")
        }

        if sessions.contains(where: { $0.name == sessionName }) {
            let actualTag = try? await metadata.ownershipTag(for: sessionName)
            guard actualTag == expectedTag else {
                throw CodexRuntimeError.ownershipConflict(
                    "Refusing to reuse \(sessionName): its ownership tag does not match this launch attempt"
                )
            }
            return CodexRuntimeLaunchReceipt(binding: binding(for: sessionName))
        }

        let command = [
            "KANBAN_CODE_CARD_ID=\(ShellCommand.shellEscape(request.cardId))",
            "KANBAN_CODE_SESSION_ID=\(ShellCommand.shellEscape(sessionName))",
            "KANBAN_CODE_ATTEMPT_ID=\(ShellCommand.shellEscape(request.attemptId))",
            "KANBAN_CODE_GENERATION=\(request.generation)",
            "KANBAN_CODE_BACKEND=\(CodexRuntimeBackend.cliTmux.rawValue)",
            "KANBAN_CODE_LIFECYCLE_CAPABILITY=\(ShellCommand.shellEscape(request.lifecycleCapability))",
            "\(ShellCommand.shellEscape(codexExecutablePath)) --no-alt-screen",
        ].joined(separator: " ")
        do {
            try await tmux.createSession(
                name: sessionName,
                path: request.projectPath,
                command: command
            )
        } catch {
            throw CodexRuntimeError.notStarted("Could not create tmux session: \(error.localizedDescription)")
        }

        do {
            try await metadata.setOwnershipTag(expectedTag, for: sessionName)
            if !request.prompt.isEmpty {
                try await tmux.pastePrompt(
                    to: sessionName,
                    text: CodexManagedPrompt.withReviewReadyInstruction(
                        request.prompt,
                        request: request,
                        backend: .cliTmux,
                        sessionID: sessionName
                    )
                )
            }
        } catch let error as CodexRuntimeError {
            throw error
        } catch {
            throw CodexRuntimeError.launchUncertain(
                "tmux session \(sessionName) exists, but launch acknowledgement failed: \(error.localizedDescription)"
            )
        }

        return CodexRuntimeLaunchReceipt(binding: binding(for: sessionName))
    }

    public func recover(_ request: CodexRuntimeRecoveryRequest) async -> CodexRuntimeRecoveryResult {
        let sessionName = Self.sessionName(cardId: request.cardId, generation: request.lease.generation)
        guard let sessions = try? await tmux.listSessions() else {
            return .uncertain("Could not inspect tmux sessions")
        }
        guard sessions.contains(where: { $0.name == sessionName }) else {
            return .notStarted
        }
        guard let tag = try? await metadata.ownershipTag(for: sessionName) else {
            return .uncertain("The reserved tmux session exists without readable ownership metadata")
        }
        let expected = CodexTmuxOwnershipTag(
            cardId: request.cardId,
            attemptId: request.lease.attemptId,
            generation: request.lease.generation
        )
        guard tag == expected else {
            return .uncertain("The reserved tmux session is owned by a different launch attempt")
        }
        return .running(binding(for: sessionName))
    }

    public func sendFeedback(_ request: CodexRuntimeFeedbackRequest) async throws {
        guard request.binding.backend == .cliTmux,
              let sessionName = request.binding.tmuxSessionName else {
            throw CodexRuntimeError.invalidBinding("The task is not bound to a Codex CLI tmux session")
        }
        guard let tag = try await metadata.ownershipTag(for: sessionName), tag.cardId == request.cardId else {
            throw CodexRuntimeError.ownershipConflict(
                "Refusing to send feedback to a tmux session not owned by this card"
            )
        }
        try await tmux.pastePrompt(to: sessionName, text: request.body)
    }

    public static func sessionName(cardId: String, generation: Int) -> String {
        let safeCardId = cardId.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(String(scalar)) : "-"
        }
        return "kanban-code-\(String(safeCardId))-\(generation)"
    }

    private func binding(for sessionName: String) -> CodexExecutionBinding {
        CodexExecutionBinding(
            backend: .cliTmux,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .limited,
            tmuxSessionName: sessionName,
            boundAt: .now
        )
    }

}
