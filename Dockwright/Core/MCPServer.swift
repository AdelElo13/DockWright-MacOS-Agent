import Foundation
import Network
import os

// MARK: - Model Context Protocol (MCP) Server
// Implements the MCP standard for tool discovery and execution.
// Runs on port 8767 alongside the AI-to-AI server (8766).
// Any MCP-compatible client can discover and invoke Dockwright's tools.
//
// Endpoints:
//   POST /mcp/tools/list     → List all available tools with schemas
//   POST /mcp/tools/call     → Execute a tool by name with arguments
//   GET  /mcp/status         → Health check
//   OPTIONS *                → CORS preflight

private nonisolated let mcpLog = Logger(subsystem: "com.Aatje.Dockwright", category: "MCPServer")

actor MCPServer {
    static let shared = MCPServer()

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var isRunning = false
    private let port: UInt16 = 8767
    private let maxMessageSize = 1_048_576

    /// Direct references to shared singletons — no closure isolation issues
    private let registry = ToolRegistry.shared
    private var executor: ToolExecutor?

    private init() {}

    func setExecutor(_ executor: ToolExecutor) {
        self.executor = executor
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            mcpLog.error("[MCP] Invalid port \(self.port)")
            return
        }

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    mcpLog.info("[MCP] Listening on port \(self.port)")
                case .failed(let error):
                    mcpLog.error("[MCP] Failed: \(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                Task { await self.handleNewConnection(conn) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            isRunning = true
            mcpLog.info("[MCP] Server started on port \(self.port)")
        } catch {
            mcpLog.error("[MCP] Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        isRunning = false
        mcpLog.info("[MCP] Server stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ conn: NWConnection) {
        let id = UUID()
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                Task { await self?.removeConnection(id) }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveData(conn: conn, id: id)
    }

    private func removeConnection(_ id: UUID) {
        connections[id] = nil
    }

    private func receiveData(conn: NWConnection, id: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: maxMessageSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data = data, !data.isEmpty {
                Task { await self.handleHTTPRequest(data: data, conn: conn, id: id) }
            }

            if let error = error {
                mcpLog.warning("[MCP] Receive error: \(error)")
                conn.cancel()
                return
            }

            if isComplete {
                conn.cancel()
            }
        }
    }

    // MARK: - HTTP Handling

    private func handleHTTPRequest(data: Data, conn: NWConnection, id: UUID) async {
        guard let request = String(data: data, encoding: .utf8) else {
            sendResponse(conn: conn, status: 400, body: #"{"error":"Invalid data"}"#)
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(conn: conn, status: 400, body: #"{"error":"No request line"}"#)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(conn: conn, status: 400, body: #"{"error":"Malformed request"}"#)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // CORS preflight
        if method == "OPTIONS" {
            sendResponse(conn: conn, status: 200, body: "", extraHeaders: corsHeaders)
            return
        }

        // Extract body (after double CRLF)
        let bodyString: String
        if let range = request.range(of: "\r\n\r\n") {
            bodyString = String(request[range.upperBound...])
        } else {
            bodyString = ""
        }

        switch (method, path) {
        case ("GET", "/mcp/status"):
            let json = #"{"status":"ok","protocol":"mcp","version":"2024-11-05","port":\#(port),"tools_available":true}"#
            sendResponse(conn: conn, status: 200, body: json)

        case ("POST", "/mcp/tools/list"):
            await handleToolsList(conn: conn)

        case ("POST", "/mcp/tools/call"):
            await handleToolCall(conn: conn, body: bodyString)

        default:
            sendResponse(conn: conn, status: 404, body: #"{"error":"Not found. Endpoints: /mcp/tools/list, /mcp/tools/call, /mcp/status"}"#)
        }
    }

    // MARK: - Tool List

    private func handleToolsList(conn: NWConnection) async {
        let tools = registry.mcpToolDefinitions()

        let response: [String: Any] = [
            "tools": tools
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sendResponse(conn: conn, status: 200, body: jsonStr)
        } else {
            sendResponse(conn: conn, status: 500, body: #"{"error":"Failed to serialize tools"}"#)
        }
    }

    // MARK: - Tool Call

    private func handleToolCall(conn: NWConnection, body: String) async {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            sendResponse(conn: conn, status: 400, body: #"{"error":"Invalid JSON body. Expected: {\"name\":\"tool_name\",\"arguments\":{...}}"}"#)
            return
        }

        guard let toolName = json["name"] as? String else {
            sendResponse(conn: conn, status: 400, body: #"{"error":"Missing 'name' field"}"#)
            return
        }

        let arguments = json["arguments"] as? [String: Any] ?? [:]

        guard let executor = executor else {
            sendResponse(conn: conn, status: 500, body: #"{"error":"Tool executor not configured. Call setExecutor() first."}"#)
            return
        }

        mcpLog.info("[MCP] Calling tool: \(toolName)")
        let startTime = Date()

        let toolResult: ToolResult
        do {
            toolResult = try await executor.executeTool(name: toolName, arguments: arguments)
        } catch {
            sendResponse(conn: conn, status: 500, body: #"{"error":"Tool execution failed: \#(error.localizedDescription)"}"#)
            return
        }
        let output = toolResult.output
        let isError = toolResult.isError

        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

        let response: [String: Any] = [
            "content": [
                ["type": "text", "text": output]
            ],
            "isError": isError,
            "meta": [
                "tool": toolName,
                "execution_time_ms": elapsed,
            ] as [String: Any],
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sendResponse(conn: conn, status: 200, body: jsonStr)
        } else {
            sendResponse(conn: conn, status: 500, body: #"{"error":"Failed to serialize result"}"#)
        }

        mcpLog.info("[MCP] Tool \(toolName) completed in \(elapsed)ms")
    }

    // MARK: - HTTP Response

    private let corsHeaders = [
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
    ]

    private func sendResponse(conn: NWConnection, status: Int, body: String, extraHeaders: [String] = []) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
        ]
        headers.append(contentsOf: corsHeaders)
        headers.append(contentsOf: extraHeaders)
        headers.append("")
        headers.append(body)

        let response = headers.joined(separator: "\r\n")
        if let data = response.data(using: .utf8) {
            conn.send(content: data, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
}
