import Foundation

/// JSON value used at the App Server protocol boundary. Keeping unknown fields
/// as values lets newer servers add payload data without breaking older clients.
public enum CodexJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public subscript(key: String) -> CodexJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public enum CodexRPCIdentifier: Codable, Sendable, Hashable, Equatable {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC id must be an integer or string")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var jsonValue: CodexJSONValue {
        switch self {
        case .integer(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

public struct CodexRPCError: Codable, Sendable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: CodexJSONValue?

    public init(code: Int, message: String, data: CodexJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct CodexInitializeResult: Decodable, Sendable, Equatable {
    public let userAgent: String?
    public let protocolVersion: String?
    public let capabilities: CodexJSONValue?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        userAgent = try container.decodeIfPresent(String.self, forKey: "userAgent")
        protocolVersion = try container.decodeLossyStringIfPresent(forKey: "protocolVersion")
        capabilities = try container.decodeIfPresent(CodexJSONValue.self, forKey: "capabilities")
    }
}

/// Tolerant representation of App Server's evolving thread status shape.
public struct CodexThreadStatus: Decodable, Sendable, Equatable {
    public let type: String
    public let activeFlags: [String]
    private let explicitWaitingOnApproval: Bool?

    public var waitingOnApproval: Bool {
        explicitWaitingOnApproval == true
            || type == "waitingOnApproval"
            || activeFlags.contains("waitingOnApproval")
    }

    public var waitingOnUserInput: Bool {
        type == "waitingOnUserInput" || activeFlags.contains("waitingOnUserInput")
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            type = value
            activeFlags = []
            explicitWaitingOnApproval = nil
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let primaryType = try container.decodeIfPresent(String.self, forKey: "type")
        let fallbackType = try container.decodeIfPresent(String.self, forKey: "status")
        type = primaryType ?? fallbackType ?? "unknown"
        let camelFlags = try container.decodeIfPresent([String].self, forKey: "activeFlags")
        let snakeFlags = try container.decodeIfPresent([String].self, forKey: "active_flags")
        activeFlags = camelFlags ?? snakeFlags ?? []
        let camelWaiting = try container.decodeIfPresent(Bool.self, forKey: "waitingOnApproval")
        let snakeWaiting = try container.decodeIfPresent(Bool.self, forKey: "waiting_on_approval")
        explicitWaitingOnApproval = camelWaiting ?? snakeWaiting
    }
}

public struct CodexThread: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let preview: String?
    public let cwd: String?
    public let sourceKinds: [String]
    public let status: CodexThreadStatus?
    public let archived: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try container.decode(String.self, forKey: "id")
        name = try container.decodeIfPresent(String.self, forKey: "name")
        preview = try container.decodeIfPresent(String.self, forKey: "preview")
        cwd = try container.decodeIfPresent(String.self, forKey: "cwd")
        status = try container.decodeIfPresent(CodexThreadStatus.self, forKey: "status")
        archived = try container.decodeIfPresent(Bool.self, forKey: "archived")

        if let values = try? container.decode([String].self, forKey: "sourceKinds") {
            sourceKinds = values
        } else if let value = try? container.decode(String.self, forKey: "sourceKind") {
            sourceKinds = [value]
        } else if let value = try? container.decode(String.self, forKey: "source") {
            sourceKinds = [value]
        } else {
            sourceKinds = []
        }
    }
}

public struct CodexThreadListResponse: Decodable, Sendable, Equatable {
    public let data: [CodexThread]
    public let nextCursor: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let dataValue = try container.decodeIfPresent([CodexThread].self, forKey: "data")
        let threadsValue = try container.decodeIfPresent([CodexThread].self, forKey: "threads")
        data = dataValue ?? threadsValue ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: "nextCursor")
    }
}

public struct CodexTurn: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let threadID: String?
    public let status: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try container.decode(String.self, forKey: "id")
        let camelThreadID = try container.decodeIfPresent(String.self, forKey: "threadId")
        let snakeThreadID = try container.decodeIfPresent(String.self, forKey: "thread_id")
        threadID = camelThreadID ?? snakeThreadID
        status = try container.decodeIfPresent(String.self, forKey: "status")
    }
}

public struct CodexThreadStatusChanged: Decodable, Sendable, Equatable {
    public let threadID: String
    public let status: CodexThreadStatus

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let camelThreadID = try container.decodeIfPresent(String.self, forKey: "threadId")
        threadID = try camelThreadID ?? container.decode(String.self, forKey: "thread_id")
        status = try container.decode(CodexThreadStatus.self, forKey: "status")
    }
}

public struct CodexAppServerNotification: Sendable, Equatable {
    public let method: String
    public let params: CodexJSONValue
    public let generation: UInt64

    public func decodeParams<Value: Decodable>(as type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(type, from: data)
    }
}

public struct CodexAppServerRequest: Sendable, Equatable {
    public let id: CodexRPCIdentifier
    public let method: String
    public let params: CodexJSONValue
    public let generation: UInt64

    public func decodeParams<Value: Decodable>(as type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(type, from: data)
    }
}

struct CodexRPCMessage: Decodable {
    let id: CodexRPCIdentifier?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: CodexRPCError?
}

struct CodexThreadEnvelope: Decodable {
    let thread: CodexThread
}

struct CodexTurnEnvelope: Decodable {
    let turn: CodexTurn
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    static func key(_ value: String) -> DynamicCodingKey {
        DynamicCodingKey(stringValue: value)!
    }
}

private extension KeyedDecodingContainer where Key == DynamicCodingKey {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        try decode(type, forKey: .key(key))
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try decodeIfPresent(type, forKey: .key(key))
    }

    func decodeLossyStringIfPresent(forKey key: String) throws -> String? {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        return nil
    }
}
