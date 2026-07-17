import Foundation

/// A discovered coding assistant session, extracted from session files.
public struct Session: Identifiable, Codable, Sendable, Equatable {
    public let id: String // sessionId (UUID string)
    public var name: String? // Custom name or auto-generated summary
    public var firstPrompt: String? // First user message text
    public var projectPath: String? // Decoded project directory path
    public var gitBranch: String? // Git branch if in a worktree
    public var messageCount: Int
    public var modifiedTime: Date
    public var jsonlPath: String? // Full path to the session file (.jsonl or .json)
    public var assistant: CodingAssistant // Which assistant this session belongs to
    public var runtimeProvenance: CodexRuntimeProvenance? // nil when origin is not known or not Codex
    public var runtimeLifecycle: LifecycleSnapshot? // structured App Server status when available

    public init(
        id: String,
        name: String? = nil,
        firstPrompt: String? = nil,
        projectPath: String? = nil,
        gitBranch: String? = nil,
        messageCount: Int = 0,
        modifiedTime: Date = .now,
        jsonlPath: String? = nil,
        assistant: CodingAssistant = .claude,
        runtimeProvenance: CodexRuntimeProvenance? = nil,
        runtimeLifecycle: LifecycleSnapshot? = nil
    ) {
        self.id = id
        self.name = name
        self.firstPrompt = firstPrompt
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.modifiedTime = modifiedTime
        self.jsonlPath = jsonlPath
        self.assistant = assistant
        self.runtimeProvenance = runtimeProvenance
        self.runtimeLifecycle = runtimeLifecycle
    }

    /// Display title: custom name → summary → first prompt → session ID prefix.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let firstPrompt, !firstPrompt.isEmpty {
            return String(firstPrompt.prefix(100))
        }
        return String(id.prefix(8)) + "..."
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, firstPrompt, projectPath, gitBranch, messageCount, modifiedTime
        case jsonlPath, assistant, runtimeProvenance, runtimeLifecycle
    }

    /// Field-isolated decoding keeps older discovery snapshots readable and
    /// prevents a future provenance value from invalidating the session.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        firstPrompt = try? container.decodeIfPresent(String.self, forKey: .firstPrompt)
        projectPath = try? container.decodeIfPresent(String.self, forKey: .projectPath)
        gitBranch = try? container.decodeIfPresent(String.self, forKey: .gitBranch)
        messageCount = (try? container.decodeIfPresent(Int.self, forKey: .messageCount)) ?? 0
        modifiedTime = (try? container.decodeIfPresent(Date.self, forKey: .modifiedTime)) ?? .now
        jsonlPath = try? container.decodeIfPresent(String.self, forKey: .jsonlPath)
        assistant = (try? container.decodeIfPresent(CodingAssistant.self, forKey: .assistant)) ?? .claude
        runtimeProvenance = try? container.decodeIfPresent(CodexRuntimeProvenance.self, forKey: .runtimeProvenance)
        runtimeLifecycle = try? container.decodeIfPresent(LifecycleSnapshot.self, forKey: .runtimeLifecycle)
    }
}
