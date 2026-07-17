import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("CodexAppServerClient")
struct CodexAppServerClientTests {
    @Test("Correlates interleaved responses and sends initialized notification")
    func correlatesInterleavedResponses() async throws {
        let transport = FakeCodexAppServerLineTransport()
        let client = CodexAppServerClient(transport: transport, requestTimeout: .seconds(1))
        await client.start()

        async let initialized = client.initialize(clientName: "tests", clientVersion: "1")
        let initializeRequest = try await transport.nextSentMessage()
        #expect(initializeRequest.method == "initialize")
        await transport.receive(response: .object([
            "userAgent": .string("codex-test"),
            "protocolVersion": .string("1"),
        ]), for: initializeRequest.id)
        let initializeResult = try await initialized
        #expect(initializeResult.userAgent == "codex-test")

        let initializedNotification = try await transport.nextSentMessage()
        #expect(initializedNotification.method == "initialized")
        #expect(initializedNotification.id == nil)

        async let list = client.listThreads(limit: 25, sourceKinds: ["appServer", "cli"])
        async let started = client.startThread(cwd: "/tmp/project")
        let first = try await transport.nextSentMessage()
        let second = try await transport.nextSentMessage()
        let listRequest = first.method == "thread/list" ? first : second
        let startRequest = first.method == "thread/start" ? first : second

        await transport.receive(response: .object([
            "thread": .object([
                "id": .string("thread-new"),
                "cwd": .string("/tmp/project"),
                "sourceKind": .string("appServer"),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([.string("waitingOnApproval")]),
                ]),
            ]),
        ]), for: startRequest.id)
        await transport.receive(response: .object([
            "data": .array([
                .object([
                    "id": .string("thread-existing"),
                    "sourceKinds": .array([.string("cli"), .string("future-source")]),
                    "status": .string("idle"),
                ]),
            ]),
            "nextCursor": .string("page-2"),
        ]), for: listRequest.id)

        let startResult = try await started
        let listResult = try await list
        #expect(startResult.id == "thread-new")
        #expect(startResult.sourceKinds == ["appServer"])
        #expect(startResult.status?.waitingOnApproval == true)
        #expect(listResult.data.first?.sourceKinds == ["cli", "future-source"])
        #expect(listResult.data.first?.status?.type == "idle")
        #expect(listResult.nextCursor == "page-2")
    }

    @Test("Builds resume, turn start, and turn steer requests")
    func buildsThreadAndTurnRequests() async throws {
        let transport = FakeCodexAppServerLineTransport()
        let client = CodexAppServerClient(transport: transport, requestTimeout: .seconds(1))
        await client.start()

        async let resumed = client.resumeThread(id: "thread-1")
        let resumeRequest = try await transport.nextSentMessage()
        #expect(resumeRequest.method == "thread/resume")
        #expect(resumeRequest.params?["threadId"] == .string("thread-1"))
        await transport.receive(response: .object([
            "thread": .object(["id": .string("thread-1")]),
        ]), for: resumeRequest.id)
        #expect((try await resumed).id == "thread-1")

        async let turn = client.startTurn(threadID: "thread-1", text: "implement it")
        let turnRequest = try await transport.nextSentMessage()
        #expect(turnRequest.method == "turn/start")
        #expect(turnRequest.params?["threadId"] == .string("thread-1"))
        await transport.receive(response: .object([
            "turn": .object(["id": .string("turn-1"), "status": .string("inProgress")]),
        ]), for: turnRequest.id)
        #expect((try await turn).id == "turn-1")

        async let steered = client.steerTurn(threadID: "thread-1", turnID: "turn-1", text: "also add tests")
        let steerRequest = try await transport.nextSentMessage()
        #expect(steerRequest.method == "turn/steer")
        #expect(steerRequest.params?["expectedTurnId"] == .string("turn-1"))
        await transport.receive(response: .object([
            "turnId": .string("turn-1"),
        ]), for: steerRequest.id)
        #expect(try await steered == "turn-1")
    }

    @Test("Streams notifications and only allowlisted server requests")
    func streamsInboundMessages() async throws {
        let transport = FakeCodexAppServerLineTransport()
        let client = CodexAppServerClient(transport: transport, requestTimeout: .seconds(1))
        let notifications = await client.notifications()
        let requests = await client.serverRequests()
        await client.start()

        let notificationTask = Task { try await firstValue(from: notifications) }
        await transport.receive(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-1"),
            "status": .object([
                "type": .string("active"),
                "activeFlags": .array([.string("waitingOnApproval")]),
            ]),
        ]))
        let notification = try await notificationTask.value
        let changed = try notification.decodeParams(as: CodexThreadStatusChanged.self)
        #expect(changed.threadID == "thread-1")
        #expect(changed.status.waitingOnApproval)

        await transport.receive(
            id: .string("server-1"),
            method: "item/commandExecution/requestApproval",
            params: .object(["command": .string("swift test")])
        )
        var requestIterator = requests.makeAsyncIterator()
        let request = await requestIterator.next()
        #expect(request?.method == "item/commandExecution/requestApproval")
        try await client.respond(to: request!, result: .object(["decision": .string("accept")]))
        let response = try await transport.nextSentMessage()
        #expect(response.id == .string("server-1"))
        #expect(response.result?["decision"] == .string("accept"))

        await transport.receive(
            id: .string("server-2"),
            method: "dangerous/unknownRequest",
            params: .object([:])
        )
        let rejection = try await transport.nextSentMessage()
        #expect(rejection.id == .string("server-2"))
        #expect(rejection.error?.code == -32601)
    }

    @Test("Times out pending requests and fails them on disconnect")
    func timeoutAndDisconnect() async throws {
        let timeoutTransport = FakeCodexAppServerLineTransport()
        let timeoutClient = CodexAppServerClient(transport: timeoutTransport, requestTimeout: .milliseconds(30))
        await timeoutClient.start()

        do {
            _ = try await timeoutClient.listThreads()
            Issue.record("Expected timeout")
        } catch let error as CodexAppServerClientError {
            #expect(error == .requestTimedOut(method: "thread/list"))
        }

        let disconnectTransport = FakeCodexAppServerLineTransport()
        let disconnectClient = CodexAppServerClient(transport: disconnectTransport, requestTimeout: .seconds(1))
        await disconnectClient.start()
        let initialGeneration = await disconnectClient.generation
        let pending = Task { try await disconnectClient.resumeThread(id: "thread-1") }
        _ = try await disconnectTransport.nextSentMessage()
        await disconnectTransport.finish()

        do {
            _ = try await pending.value
            Issue.record("Expected disconnect")
        } catch let error as CodexAppServerClientError {
            #expect(error == .disconnected)
        }
        #expect(await disconnectClient.generation == initialGeneration + 1)
    }

    @Test("Concurrent connection callers share one in-flight client factory")
    func connectionCoalescesConcurrentCallers() async throws {
        let factory = CountingClientFactory()
        let connection = CodexAppServerConnection(makeClient: { try await factory.make() })

        async let first = connection.client()
        async let second = connection.client()
        let (a, b) = try await (first, second)

        #expect(a === b)
        #expect(await factory.count == 1)
    }

    private func firstValue<Element: Sendable>(from stream: AsyncStream<Element>) async throws -> Element {
        var iterator = stream.makeAsyncIterator()
        guard let value = await iterator.next() else {
            throw TestError.streamEnded
        }
        return value
    }

    private enum TestError: Error {
        case streamEnded
    }
}

private actor CountingClientFactory {
    private(set) var count = 0

    func make() async throws -> CodexAppServerClient {
        count += 1
        try await Task.sleep(for: .milliseconds(30))
        let client = CodexAppServerClient(transport: FakeCodexAppServerLineTransport())
        await client.start()
        return client
    }
}

private actor FakeCodexAppServerLineTransport: CodexAppServerLineTransport {
    private var inbound: [String] = []
    private var inboundWaiters: [CheckedContinuation<String?, Error>] = []
    private var sent: [String] = []
    private var sentWaiters: [CheckedContinuation<String, Never>] = []
    private var finished = false

    func writeLine(_ line: String) async throws {
        if let waiter = sentWaiters.first {
            sentWaiters.removeFirst()
            waiter.resume(returning: line)
        } else {
            sent.append(line)
        }
    }

    func readLine() async throws -> String? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { inboundWaiters.append($0) }
    }

    func nextSentMessage() async throws -> TestRPCMessage {
        let line: String
        if !sent.isEmpty {
            line = sent.removeFirst()
        } else {
            line = await withCheckedContinuation { sentWaiters.append($0) }
        }
        return try JSONDecoder().decode(TestRPCMessage.self, from: Data(line.utf8))
    }

    func receive(response: CodexJSONValue, for id: CodexRPCIdentifier?) {
        guard let id else { return }
        receiveObject(["jsonrpc": .string("2.0"), "id": id.jsonValue, "result": response])
    }

    func receive(method: String, params: CodexJSONValue) {
        receiveObject(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }

    func receive(id: CodexRPCIdentifier, method: String, params: CodexJSONValue) {
        receiveObject([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "method": .string(method),
            "params": params,
        ])
    }

    func finish() {
        finished = true
        let waiters = inboundWaiters
        inboundWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    private func receiveObject(_ object: [String: CodexJSONValue]) {
        let data = try! JSONEncoder().encode(CodexJSONValue.object(object))
        let line = String(decoding: data, as: UTF8.self)
        if let waiter = inboundWaiters.first {
            inboundWaiters.removeFirst()
            waiter.resume(returning: line)
        } else {
            inbound.append(line)
        }
    }
}

private struct TestRPCMessage: Decodable {
    let id: CodexRPCIdentifier?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: CodexRPCError?
}
