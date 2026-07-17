import Foundation

/// Minimal newline-delimited transport boundary for `codex app-server`.
/// A Process-backed implementation can be added without coupling protocol tests
/// or the client actor to Foundation.Process lifecycle details.
public protocol CodexAppServerLineTransport: Sendable {
    func writeLine(_ line: String) async throws
    func readLine() async throws -> String?
}

public enum CodexAppServerClientError: Error, LocalizedError, Sendable, Equatable {
    case disconnected
    case requestTimedOut(method: String)
    case remoteError(code: Int, message: String)
    case invalidResponse(method: String)
    case serverRequestNotPending

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "Codex App Server disconnected"
        case .requestTimedOut(let method):
            "Codex App Server request timed out: \(method)"
        case .remoteError(let code, let message):
            "Codex App Server error \(code): \(message)"
        case .invalidResponse(let method):
            "Codex App Server returned an invalid response for \(method)"
        case .serverRequestNotPending:
            "Codex App Server request is no longer pending"
        }
    }
}

/// Actor-isolated JSON-RPC client for the Codex App Server protocol.
///
/// The actor owns request correlation and connection generation. A response or
/// server request from an older generation can never complete current work.
public actor CodexAppServerClient {
    public static let defaultServerRequestMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/requestUserInput",
    ]

    public private(set) var generation: UInt64 = 0

    public var isConnected: Bool { readerTask != nil }

    private let transport: any CodexAppServerLineTransport
    private let requestTimeout: Duration
    private let allowedServerRequestMethods: Set<String>
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var initializeResult: CodexInitializeResult?
    private var pendingServerRequests: [CodexRPCIdentifier: UInt64] = [:]
    private var notificationContinuations: [UUID: AsyncStream<CodexAppServerNotification>.Continuation] = [:]
    private var serverRequestContinuations: [UUID: AsyncStream<CodexAppServerRequest>.Continuation] = [:]

    public init(
        transport: any CodexAppServerLineTransport,
        requestTimeout: Duration = .seconds(10),
        allowedServerRequestMethods: Set<String> = CodexAppServerClient.defaultServerRequestMethods
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.allowedServerRequestMethods = allowedServerRequestMethods
    }

    deinit {
        readerTask?.cancel()
        for pending in pendingRequests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: CodexAppServerClientError.disconnected)
        }
        for continuation in notificationContinuations.values { continuation.finish() }
        for continuation in serverRequestContinuations.values { continuation.finish() }
    }

    /// Begin consuming inbound lines. Calling this repeatedly is idempotent.
    public func start() {
        guard readerTask == nil else { return }
        if generation == 0 { generation = 1 }
        startReader(for: generation)
    }

    /// End the current generation and fail every outstanding request.
    public func disconnect() {
        advanceGeneration()
    }

    /// Start a fresh protocol generation on the same reconnectable transport.
    /// Future Process-backed transports can swap their underlying pipes before
    /// invoking this method.
    public func beginNewGeneration() {
        advanceGeneration()
        startReader(for: generation)
    }

    public func notifications() -> AsyncStream<CodexAppServerNotification> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            notificationContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(token) }
            }
        }
    }

    public func serverRequests() -> AsyncStream<CodexAppServerRequest> {
        let token = UUID()
        return AsyncStream { continuation in
            serverRequestContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeServerRequestContinuation(token) }
            }
        }
    }

    @discardableResult
    public func initialize(clientName: String, clientVersion: String) async throws -> CodexInitializeResult {
        if let initializeResult { return initializeResult }
        let params: CodexJSONValue = .object([
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
            "capabilities": .object([:]),
        ])
        let result: CodexInitializeResult = try await request(method: "initialize", params: params)
        try await sendNotification(method: "initialized", params: .object([:]))
        initializeResult = result
        return result
    }

    public func listThreads(
        cursor: String? = nil,
        limit: Int? = nil,
        sourceKinds: [String]? = nil,
        archived: Bool? = nil
    ) async throws -> CodexThreadListResponse {
        var params: [String: CodexJSONValue] = [:]
        if let cursor { params["cursor"] = .string(cursor) }
        if let limit { params["limit"] = .number(Double(limit)) }
        if let sourceKinds { params["sourceKinds"] = .array(sourceKinds.map(CodexJSONValue.string)) }
        if let archived { params["archived"] = .bool(archived) }
        return try await request(method: "thread/list", params: .object(params))
    }

    public func startThread(
        cwd: String? = nil,
        approvalPolicy: String? = nil,
        sandbox: CodexJSONValue? = nil
    ) async throws -> CodexThread {
        var params: [String: CodexJSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        if let approvalPolicy { params["approvalPolicy"] = .string(approvalPolicy) }
        if let sandbox { params["sandbox"] = sandbox }
        let value = try await requestValue(method: "thread/start", params: .object(params))
        return try decodeEnvelopeOrValue(CodexThreadEnvelope.self, CodexThread.self, from: value, method: "thread/start") { $0.thread }
    }

    public func resumeThread(id: String) async throws -> CodexThread {
        let value = try await requestValue(
            method: "thread/resume",
            params: .object(["threadId": .string(id)])
        )
        return try decodeEnvelopeOrValue(CodexThreadEnvelope.self, CodexThread.self, from: value, method: "thread/resume") { $0.thread }
    }

    public func startTurn(threadID: String, text: String) async throws -> CodexTurn {
        let value = try await requestValue(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": textInput(text),
            ])
        )
        return try decodeEnvelopeOrValue(CodexTurnEnvelope.self, CodexTurn.self, from: value, method: "turn/start") { $0.turn }
    }

    public func steerTurn(threadID: String, turnID: String, text: String) async throws -> String {
        struct Response: Decodable { let turnId: String }
        let response: Response = try await request(
            method: "turn/steer",
            params: .object([
                "threadId": .string(threadID),
                "expectedTurnId": .string(turnID),
                "input": textInput(text),
            ])
        )
        return response.turnId
    }

    public func respond(to request: CodexAppServerRequest, result: CodexJSONValue) async throws {
        guard request.generation == generation,
              request.method.isEmpty == false,
              allowedServerRequestMethods.contains(request.method),
              pendingServerRequests[request.id] == generation
        else {
            throw CodexAppServerClientError.serverRequestNotPending
        }

        pendingServerRequests.removeValue(forKey: request.id)
        try await write(.object([
            "jsonrpc": .string("2.0"),
            "id": request.id.jsonValue,
            "result": result,
        ]))
    }

    private func textInput(_ text: String) -> CodexJSONValue {
        .array([.object(["type": .string("text"), "text": .string(text)])])
    }

    private func request<Response: Decodable>(method: String, params: CodexJSONValue) async throws -> Response {
        let value = try await requestValue(method: method, params: params)
        do {
            return try decode(Response.self, from: value)
        } catch {
            throw CodexAppServerClientError.invalidResponse(method: method)
        }
    }

    private func requestValue(method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        start()
        nextRequestID += 1
        let id = nextRequestID
        let requestGeneration = generation
        let message: CodexJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let line: String
        do {
            line = try encodeLine(message)
        } catch {
            throw CodexAppServerClientError.invalidResponse(method: method)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self, requestTimeout] in
                    do {
                        try await Task.sleep(for: requestTimeout)
                    } catch {
                        return
                    }
                    await self?.expireRequest(id: id, generation: requestGeneration)
                }
                pendingRequests[id] = PendingRequest(
                    method: method,
                    generation: requestGeneration,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self, transport] in
                    do {
                        try await transport.writeLine(line)
                    } catch {
                        await self?.transportEnded(generation: requestGeneration)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failRequest(id: id, generation: requestGeneration, error: CancellationError())
            }
        }
    }

    private func sendNotification(method: String, params: CodexJSONValue) async throws {
        start()
        try await write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func startReader(for readerGeneration: UInt64) {
        let transport = self.transport
        readerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let line = try await transport.readLine() else {
                        await self?.transportEnded(generation: readerGeneration)
                        return
                    }
                    await self?.handle(line: line, generation: readerGeneration)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.transportEnded(generation: readerGeneration)
            }
        }
    }

    private func handle(line: String, generation messageGeneration: UInt64) async {
        guard messageGeneration == generation,
              let data = line.data(using: .utf8),
              let message = try? decoder.decode(CodexRPCMessage.self, from: data)
        else { return }

        if let method = message.method {
            if let id = message.id {
                if allowedServerRequestMethods.contains(method) {
                    pendingServerRequests[id] = messageGeneration
                    let request = CodexAppServerRequest(
                        id: id,
                        method: method,
                        params: message.params ?? .object([:]),
                        generation: messageGeneration
                    )
                    for continuation in serverRequestContinuations.values {
                        continuation.yield(request)
                    }
                } else {
                    try? await sendRPCError(id: id, code: -32601, message: "Method not found")
                }
            } else {
                let notification = CodexAppServerNotification(
                    method: method,
                    params: message.params ?? .object([:]),
                    generation: messageGeneration
                )
                for continuation in notificationContinuations.values {
                    continuation.yield(notification)
                }
            }
            return
        }

        guard let id = message.id?.integerValue,
              let pending = pendingRequests.removeValue(forKey: id),
              pending.generation == messageGeneration
        else { return }
        pending.timeoutTask.cancel()
        if let error = message.error {
            pending.continuation.resume(throwing: CodexAppServerClientError.remoteError(code: error.code, message: error.message))
        } else {
            pending.continuation.resume(returning: message.result ?? .null)
        }
    }

    private func sendRPCError(id: CodexRPCIdentifier, code: Int, message: String) async throws {
        try await write(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]))
    }

    private func expireRequest(id: Int, generation requestGeneration: UInt64) {
        guard let pending = pendingRequests[id], pending.generation == requestGeneration else { return }
        pendingRequests.removeValue(forKey: id)
        pending.continuation.resume(throwing: CodexAppServerClientError.requestTimedOut(method: pending.method))
    }

    private func failRequest(id: Int, generation requestGeneration: UInt64, error: any Error) {
        guard let pending = pendingRequests[id], pending.generation == requestGeneration else { return }
        pendingRequests.removeValue(forKey: id)
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func transportEnded(generation endedGeneration: UInt64) {
        guard endedGeneration == generation else { return }
        advanceGeneration()
    }

    private func advanceGeneration() {
        generation = max(1, generation &+ 1)
        nextRequestID = 0
        readerTask?.cancel()
        readerTask = nil
        pendingServerRequests.removeAll()
        initializeResult = nil

        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexAppServerClientError.disconnected)
        }
    }

    private func write(_ value: CodexJSONValue) async throws {
        do {
            try await transport.writeLine(encodeLine(value))
        } catch {
            advanceGeneration()
            throw CodexAppServerClientError.disconnected
        }
    }

    private func encodeLine(_ value: CodexJSONValue) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from value: CodexJSONValue) throws -> Value {
        let data = try encoder.encode(value)
        return try decoder.decode(type, from: data)
    }

    private func decodeEnvelopeOrValue<Envelope: Decodable, Value: Decodable>(
        _ envelopeType: Envelope.Type,
        _ valueType: Value.Type,
        from value: CodexJSONValue,
        method: String,
        unwrap: (Envelope) -> Value
    ) throws -> Value {
        if let envelope = try? decode(envelopeType, from: value) { return unwrap(envelope) }
        if let direct = try? decode(valueType, from: value) { return direct }
        throw CodexAppServerClientError.invalidResponse(method: method)
    }

    private func removeNotificationContinuation(_ token: UUID) {
        notificationContinuations.removeValue(forKey: token)
    }

    private func removeServerRequestContinuation(_ token: UUID) {
        serverRequestContinuations.removeValue(forKey: token)
    }
}

private struct PendingRequest {
    let method: String
    let generation: UInt64
    let continuation: CheckedContinuation<CodexJSONValue, any Error>
    let timeoutTask: Task<Void, Never>
}
