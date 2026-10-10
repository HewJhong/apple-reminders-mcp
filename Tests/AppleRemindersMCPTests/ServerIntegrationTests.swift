import Foundation
import Logging
import MCP
import Testing

@testable import AppleRemindersMCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

struct ServerIntegrationTests {
    @Test("server exposes tools over stdio transport", .timeLimit(.minutes(1)))
    func serverRoundtrip() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "apple-reminders-mcp.test")
        logger.logLevel = .debug

        let serverTransport = StdioTransport(input: clientToServerRead, output: serverToClientWrite, logger: logger)
        let clientTransport = StdioTransport(input: serverToClientRead, output: clientToServerWrite, logger: logger)

        let store = MockReminderStore()
        await store.seedLists([ReminderFixtures.list()])

        let app = AppleRemindersServer(
            dependencies: .init(reminderStore: store),
            logger: logger
        )
        let client = Client(name: "TestClient", version: "1.0.0")

        try await app.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name).contains(ToolName.listLists))
        #expect(tools.map(\.name).contains(ToolName.createReminder))
        #expect(tools.map(\.name).contains(ToolName.listSources))
        #expect(tools.map(\.name).contains(ToolName.bulkMoveReminders))

        let toolResult = try await client.callTool(name: ToolName.listLists, arguments: [:])
        #expect(toolResult.isError == nil)
        let content = try #require(toolResult.content.first)
        switch content {
        case .text(let text):
            #expect(text.contains("Listed 1 reminder lists."))
            #expect(text.contains("- Inbox | id: list-1"))
        default:
            Issue.record("Expected text content")
        }

        await app.stop()
    }

    @Test("stdio compatibility transport accepts Codex initialize capabilities", .timeLimit(.minutes(1)))
    func codexInitializeCapabilitiesOverStdio() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        var logger = Logger(label: "apple-reminders-mcp.codex-compatibility-test")
        logger.logLevel = .debug

        let serverTransport = CodexCompatibilityTransport(
            upstream: StdioTransport(
                input: clientToServerRead,
                output: serverToClientWrite,
                logger: logger
            ),
            logger: logger
        )
        let store = MockReminderStore()
        await store.seedLists([ReminderFixtures.list()])
        let recorder = CapabilityRecorder()
        let app = AppleRemindersServer(
            dependencies: .init(reminderStore: store),
            logger: logger
        )

        try await app.start(transport: serverTransport) { _, capabilities in
            await recorder.record(capabilities)
        }

        try writeMessage(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex","version":"1.0.0"}}}
            """.data(using: .utf8)!,
            to: clientToServerWrite
        )

        let initializeResponse = try readMessage(from: serverToClientRead)
        #expect(initializeResponse["error"] == nil)
        #expect(await recorder.hasElicitation)

        try writeMessage(
            """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """.data(using: .utf8)!,
            to: clientToServerWrite
        )
        try writeMessage(
            """
            {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
            """.data(using: .utf8)!,
            to: clientToServerWrite
        )

        let toolsResponse = try readMessage(from: serverToClientRead)
        let result = try #require(toolsResponse["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["name"] as? String == ToolName.listLists })

        await app.stop()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }
}

private actor CapabilityRecorder {
    private(set) var hasElicitation = false

    func record(_ capabilities: Client.Capabilities) {
        hasElicitation = capabilities.elicitation != nil
    }
}

private func writeMessage(_ data: Data, to fileDescriptor: FileDescriptor) throws {
    var framed = data
    framed.append(0x0A)
    try framed.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            guard let baseAddress = buffer.baseAddress else { return }
            let remaining = UnsafeRawBufferPointer(
                start: baseAddress.advanced(by: offset),
                count: buffer.count - offset
            )
            let written = try fileDescriptor.write(remaining)
            guard written > 0 else { throw MCPTestError.zeroByteWrite }
            offset += written
        }
    }
}

private func readMessage(from fileDescriptor: FileDescriptor) throws -> [String: Any] {
    var data = Data()
    var byte = UInt8.zero

    while true {
        let count = try withUnsafeMutableBytes(of: &byte) { buffer in
            try fileDescriptor.read(into: buffer)
        }
        guard count > 0 else { throw MCPTestError.unexpectedEOF }
        if byte == 0x0A {
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        data.append(byte)
    }
}

private enum MCPTestError: Error {
    case unexpectedEOF
    case zeroByteWrite
}
