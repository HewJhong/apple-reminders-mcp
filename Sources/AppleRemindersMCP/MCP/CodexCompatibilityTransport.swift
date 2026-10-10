import Foundation
import Logging
import MCP

/// Adapts the first Codex initialize request for older MCP Swift SDK decoders.
///
/// The pinned SDK models experimental capability values as strings, while Codex
/// sends capability values as JSON objects. Removing that one optional field lets
/// the server decode the request without changing any later client messages or
/// server responses.
public actor CodexCompatibilityTransport: Transport {
    private let upstream: any Transport
    private var didRewriteInitialize = false

    public nonisolated let logger: Logger

    public init(upstream: any Transport, logger: Logger? = nil) {
        self.upstream = upstream
        self.logger = logger ?? Logger(label: "mcp.transport.codex-compatibility")
    }

    public func connect() async throws {
        try await upstream.connect()
    }

    public func disconnect() async {
        await upstream.disconnect()
    }

    public func send(_ data: Data) async throws {
        try await upstream.send(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = await upstream.receive()
                    for try await data in stream {
                        continuation.yield(rewriteInitializeIfNeeded(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func rewriteInitializeIfNeeded(_ data: Data) -> Data {
        guard !didRewriteInitialize,
            var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "initialize"
        else {
            return data
        }

        // MCP permits only one initialize request per connection. Remember that
        // request even when it has no experimental field to adapt.
        didRewriteInitialize = true

        guard var params = message["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"],
            experimental as? [String: String] == nil
        else {
            return data
        }

        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
