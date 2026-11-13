//
//  VoiceToolDebugServer.swift
//  leanring-buddy
//
//  Debug builds only, and only when Clicky is launched with --voice-tool-debug-server.
//  Serves the same voice tools the router uses as a tiny MCP endpoint
//  (JSON-RPC over HTTP POST at http://127.0.0.1:8790/mcp), so an agent such as Claude Code, or
//  verify-clicky with curl, can turn the model or seek the video without speaking.
//  It answers only loopback requests that carry no Origin header and send JSON, so a web page
//  open in a browser cannot reach it.
//

#if DEBUG
import Foundation
import Network

@MainActor
final class VoiceToolDebugServer {
    static let port: UInt16 = 8790

    private let listTools: @MainActor () async -> [VoiceToolDescriptor]
    private let callTool: @MainActor (String, [String: JSONValue]) async -> VoiceToolOutcome
    private var listener: NWListener?

    init(
        listTools: @escaping @MainActor () async -> [VoiceToolDescriptor],
        callTool: @escaping @MainActor (String, [String: JSONValue]) async -> VoiceToolOutcome
    ) {
        self.listTools = listTools
        self.callTool = callTool
    }

    func start() {
        guard listener == nil, let listenerPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: listenerPort)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.serve(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            print("Voice tool debug server: listening on http://127.0.0.1:\(Self.port)/mcp")
        } catch {
            print("Voice tool debug server: could not listen on \(Self.port): \(error)")
        }
    }

    /// Connections whose whole request has arrived. A tool such as find_moment can run longer than the
    /// receive limit, so only a request still arriving is cut off.
    private var connectionsWithAWholeRequest: Set<ObjectIdentifier> = []

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, bytesSoFar: Data())
        // A sender that never finishes its request would keep the connection open forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.connectionsWithAWholeRequest.contains(ObjectIdentifier(connection)) else { return }
            connection.cancel()
        }
    }

    /// Reads until the headers and the Content-Length body have arrived, then answers once and closes.
    private func receiveRequest(on connection: NWConnection, bytesSoFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] receivedBytes, _, isComplete, receiveError in
            Task { @MainActor in
                guard let self else { return }
                var requestBytes = bytesSoFar
                if let receivedBytes { requestBytes.append(receivedBytes) }
                if let parsedRequest = DebugHTTPRequest(bytes: requestBytes) {
                    self.connectionsWithAWholeRequest.insert(ObjectIdentifier(connection))
                    let responseBytes = await self.response(to: parsedRequest)
                    connection.send(content: responseBytes, completion: .contentProcessed { _ in
                        connection.cancel()
                        Task { @MainActor in self.connectionsWithAWholeRequest.remove(ObjectIdentifier(connection)) }
                    })
                } else if isComplete || receiveError != nil || requestBytes.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, bytesSoFar: requestBytes)
                }
            }
        }
    }

    private func response(to request: DebugHTTPRequest) async -> Data {
        guard request.method == "POST", request.path == "/mcp" else {
            return httpResponse(status: "404 Not Found", body: nil)
        }
        // A browser adds Origin to every cross-site request, and a JSON content type forces a preflight this server never answers.
        guard request.headers["origin"] == nil,
              request.headers["content-type"]?.hasPrefix("application/json") == true else {
            return httpResponse(status: "403 Forbidden", body: nil)
        }
        guard let rpcRequest = try? JSONDecoder().decode(JSONValue.self, from: request.body),
              let method = rpcRequest["method"]?.stringValue else {
            return httpResponse(status: "400 Bad Request", body: rpcError(id: .null, code: -32700, message: "Body must be a JSON-RPC request"))
        }
        // A notification has no id and gets no reply.
        guard let requestID = rpcRequest["id"] else {
            return httpResponse(status: "202 Accepted", body: nil)
        }
        let result: JSONValue
        switch method {
        case "initialize":
            result = .object([
                "protocolVersion": rpcRequest["params"]?["protocolVersion"] ?? .string("2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("clicky"), "version": .string("debug")]),
            ])
        case "tools/list":
            let tools = await listTools()
            result = .object(["tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": .object(["readOnlyHint": .bool(tool.readOnly)]),
                ])
            })])
        case "tools/call":
            guard let toolName = rpcRequest["params"]?["name"]?.stringValue else {
                return httpResponse(status: "200 OK", body: rpcError(id: requestID, code: -32602, message: "params.name is required"))
            }
            let toolInput = rpcRequest["params"]?["arguments"]?.objectValue ?? [:]
            let outcome = await callTool(toolName, toolInput)
            print("Voice tool debug server: \(toolName) \(JSONValue.object(toolInput).compactJSONText) -> \(outcome.toolResultText)")
            result = .object([
                "content": .array([.object(["type": .string("text"), "text": .string(outcome.toolResultText)])]),
                "isError": .bool(outcome.isFailure),
            ])
        default:
            return httpResponse(status: "200 OK", body: rpcError(id: requestID, code: -32601, message: "Unknown method \(method)"))
        }
        let rpcResponse = JSONValue.object(["jsonrpc": .string("2.0"), "id": requestID, "result": result])
        return httpResponse(status: "200 OK", body: rpcResponse)
    }

    private func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }

    private func httpResponse(status: String, body: JSONValue?) -> Data {
        let bodyBytes = body.map { Data($0.compactJSONText.utf8) } ?? Data()
        var headerText = "HTTP/1.1 \(status)\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n"
        if body != nil { headerText += "Content-Type: application/json\r\n" }
        headerText += "\r\n"
        return Data(headerText.utf8) + bodyBytes
    }
}

/// Just enough HTTP/1.1 for one request: the request line, the headers, and a Content-Length body.
/// Nil until every byte of the body has arrived.
nonisolated struct DebugHTTPRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(bytes: Data) {
        guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
        var headerLines = headerText.components(separatedBy: "\r\n")
        let requestLineParts = headerLines.removeFirst().split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for headerLine in headerLines {
            guard let colonIndex = headerLine.firstIndex(of: ":") else { continue }
            let headerName = headerLine[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            headers[headerName] = headerLine[headerLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative length would trap in prefix(_:), and the server reads at most 1 MB.
        guard let contentLength = Int(headers["content-length"] ?? "0"), (0...1_000_000).contains(contentLength) else { return nil }
        let bodyBytes = bytes[headerEnd.upperBound...]
        guard bodyBytes.count >= contentLength else { return nil }
        method = String(requestLineParts[0])
        path = String(requestLineParts[1])
        self.headers = headers
        body = Data(bodyBytes.prefix(contentLength))
    }
}
#endif
