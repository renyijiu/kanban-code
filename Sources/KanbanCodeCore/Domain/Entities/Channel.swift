import Foundation

/// A chat channel — a named room agents can join, send, and broadcast into.
///
/// Mirrors the JSON format written by the TypeScript CLI at:
///   ~/.kanban-code/channels/channels.json
public struct Channel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var createdAt: Date
    public var createdBy: ChannelParticipant
    public var members: [ChannelMember]
    /// Manual display order in the sidebar. nil falls back to creation time
    /// for channels written by older app or CLI versions.
    public var sortOrder: Int?

    public init(
        id: String,
        name: String,
        createdAt: Date,
        createdBy: ChannelParticipant,
        members: [ChannelMember] = [],
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.members = members
        self.sortOrder = sortOrder
    }
}

/// A participant reference — either a real card (cardId non-nil) or the human user (cardId nil).
public struct ChannelParticipant: Codable, Sendable, Equatable, Hashable {
    public var cardId: String?
    public var handle: String

    public init(cardId: String?, handle: String) {
        self.cardId = cardId
        self.handle = handle
    }
}

public struct ChannelMember: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var cardId: String?
    public var handle: String
    public var joinedAt: Date

    public var id: String { "\(cardId ?? "user"):\(handle)" }

    public init(cardId: String?, handle: String, joinedAt: Date) {
        self.cardId = cardId
        self.handle = handle
        self.joinedAt = joinedAt
    }
}

/// A single message in a channel log (`<name>.jsonl`).
public struct ChannelMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var ts: Date
    public var from: ChannelParticipant
    public var body: String
    public var type: MessageType
    /// Absolute filesystem paths to image attachments persisted under
    /// `<baseDir>/images/<msg_id>/N.png`. `nil` means no attachments (keeps
    /// existing jsonl lines backwards-compatible).
    public var imagePaths: [String]?

    public enum MessageType: String, Codable, Sendable, Equatable {
        case message
        case join
        case leave
        case system
    }

    public init(
        id: String,
        ts: Date,
        from: ChannelParticipant,
        body: String,
        type: MessageType = .message,
        imagePaths: [String]? = nil
    ) {
        self.id = id
        self.ts = ts
        self.from = from
        self.body = body
        self.type = type
        self.imagePaths = imagePaths
    }

    private enum CodingKeys: String, CodingKey {
        case id, ts, from, body, type, imagePaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(Date.self, forKey: .ts)
        from = try c.decode(ChannelParticipant.self, forKey: .from)
        body = try c.decode(String.self, forKey: .body)
        type = (try? c.decodeIfPresent(MessageType.self, forKey: .type)) ?? .message
        imagePaths = try? c.decodeIfPresent([String].self, forKey: .imagePaths)
    }
}

/// Top-level container written to channels.json.
public struct ChannelsContainer: Codable, Sendable {
    public var channels: [Channel]
    public init(channels: [Channel] = []) { self.channels = channels }
}
