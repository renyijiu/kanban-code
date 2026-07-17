import Foundation

/// Stable input for a single managed launch attempt. The scheduler persists a
/// matching `LaunchLease` before handing this value to a runtime adapter.
public struct CodexRuntimeLaunchRequest: Sendable, Equatable {
    public var cardId: String
    public var attemptId: String
    public var generation: Int
    public var lifecycleCapability: String
    public var projectPath: String
    public var prompt: String

    public init(
        cardId: String,
        attemptId: String,
        generation: Int,
        lifecycleCapability: String,
        projectPath: String,
        prompt: String
    ) {
        self.cardId = cardId
        self.attemptId = attemptId
        self.generation = generation
        self.lifecycleCapability = lifecycleCapability
        self.projectPath = projectPath
        self.prompt = prompt
    }
}

public struct CodexRuntimeRecoveryRequest: Sendable, Equatable {
    public var cardId: String
    public var lease: LaunchLease
    public var binding: CodexExecutionBinding?

    public init(cardId: String, lease: LaunchLease, binding: CodexExecutionBinding? = nil) {
        self.cardId = cardId
        self.lease = lease
        self.binding = binding
    }
}

public struct CodexRuntimeFeedbackRequest: Sendable, Equatable {
    public var cardId: String
    public var binding: CodexExecutionBinding
    public var body: String

    public init(cardId: String, binding: CodexExecutionBinding, body: String) {
        self.cardId = cardId
        self.binding = binding
        self.body = body
    }
}

public struct CodexRuntimeLaunchReceipt: Sendable, Equatable {
    public var binding: CodexExecutionBinding

    public init(binding: CodexExecutionBinding) {
        self.binding = binding
    }
}

/// Result of comparing a durable launch lease with external runtime state.
public enum CodexRuntimeRecoveryResult: Sendable, Equatable {
    /// The side effect is definitely absent, so starting a new generation is safe.
    case notStarted
    case running(CodexExecutionBinding)
    case stopped(CodexExecutionBinding?)
    /// The adapter cannot prove whether the side effect exists. The scheduler
    /// must retain the slot and must not launch again automatically.
    case uncertain(String)
}

public enum CodexRuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// The adapter failed before it could create runtime work.
    case notStarted(String)
    /// Work may have been created. Recovery is required before another attempt.
    case launchUncertain(String)
    /// A stable runtime binding was acknowledged before a later launch stage
    /// failed. Persisting the binding lets recovery inspect the exact work.
    case partialLaunch(String, CodexExecutionBinding)
    case invalidBinding(String)
    case ownershipConflict(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted(let message), .launchUncertain(let message),
             .invalidBinding(let message), .ownershipConflict(let message),
             .unavailable(let message):
            message
        case .partialLaunch(let message, _):
            message
        }
    }

    public var mayHaveStartedWork: Bool {
        switch self {
        case .launchUncertain, .partialLaunch: true
        default: false
        }
    }
}

/// Runtime-neutral managed Codex operations. UI and scheduling code depend on
/// this port instead of directly starting processes or writing bindings.
public protocol CodexRuntimePort: Sendable {
    var backend: CodexRuntimeBackend { get }

    func launch(_ request: CodexRuntimeLaunchRequest) async throws -> CodexRuntimeLaunchReceipt
    func recover(_ request: CodexRuntimeRecoveryRequest) async -> CodexRuntimeRecoveryResult
    func sendFeedback(_ request: CodexRuntimeFeedbackRequest) async throws
}

/// Supplies managed agents with the structured, authenticated handoff they
/// must use instead of relying on natural-language completion guesses.
public enum CodexManagedPrompt {
    public static func withReviewReadyInstruction(
        _ prompt: String,
        request: CodexRuntimeLaunchRequest,
        backend: CodexRuntimeBackend,
        sessionID: String,
        helperPath: String = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/bin/kanban-code-lifecycle")
    ) -> String {
        let command = [
            "KANBAN_CODE_CARD_ID=\(ShellCommand.shellEscape(request.cardId))",
            "KANBAN_CODE_SESSION_ID=\(ShellCommand.shellEscape(sessionID))",
            "KANBAN_CODE_ATTEMPT_ID=\(ShellCommand.shellEscape(request.attemptId))",
            "KANBAN_CODE_GENERATION=\(request.generation)",
            "KANBAN_CODE_BACKEND=\(backend.rawValue)",
            "KANBAN_CODE_LIFECYCLE_CAPABILITY=\(ShellCommand.shellEscape(request.lifecycleCapability))",
            "\(ShellCommand.shellEscape(helperPath)) review-ready",
        ].joined(separator: " ")
        return """
        \(prompt)

        [Kanban Code lifecycle]
        When the deliverable is ready for human review, run this exact local command once:
        \(command)
        Do not treat a normal turn stop as completion.
        """
    }

}
