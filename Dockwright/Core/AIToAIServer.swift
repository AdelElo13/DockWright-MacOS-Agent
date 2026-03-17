import Foundation
import Network
import os

// MARK: - AI-to-AI Communication Server
// Lightweight HTTP server on port 8766 for programmatic testing and inter-agent communication.
// Localhost-only — no auth required for local connections.
//
// Endpoints:
//   POST /ai-to-ai        → Execute natural language task
//   GET  /ai-to-ai/status → Health check
//   OPTIONS *              → CORS preflight

private nonisolated let a2aLog = Logger(subsystem: "com.Aatje.Dockwright", category: "aitoai")

actor AIToAIServer {
    static let shared = AIToAIServer()

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var isRunning = false
    private var port: UInt16 = 8766
    private let maxMessageSize = 1_048_576 // 1MB
    private let maxConnections = 20

    /// Callback to execute tasks. Wired from AppState.
    /// Parameters: (task text, reply callback(result, toolsProof))
    var onRequest: (@Sendable (_ text: String, _ reply: @escaping @Sendable (String) -> Void) -> Void)?

    private init() {}

    func setOnRequest(_ handler: @escaping @Sendable (_ text: String, _ reply: @escaping @Sendable (String) -> Void) -> Void) {
        self.onRequest = handler
    }

    // MARK: - Lifecycle

    func start(port: UInt16 = 8766) throws {
        guard !isRunning else { return }
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            a2aLog.error("[A2A] Invalid port \(port)")
            return
        }

        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                a2aLog.info("[A2A] Listening on port \(port)")
            case .failed(let error):
                a2aLog.error("[A2A] Failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.handleNewConnection(conn) }
        }
        listener.start(queue: DispatchQueue(label: "com.dockwright.aitoai"))
        self.listener = listener
        self.isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        isRunning = false
        a2aLog.info("[A2A] Stopped")
    }

    var running: Bool { isRunning }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.receiveHTTP(connection: connection, id: id) }
            case .failed, .cancelled:
                Task { await self.removeConnection(id: id) }
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.dockwright.aitoai.\(id)"))
    }

    private func removeConnection(id: UUID) {
        connections.removeValue(forKey: id)
    }

    // MARK: - HTTP Parsing

    private func receiveHTTP(connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxMessageSize) { [weak self] data, _, _, error in
            guard let self, let data else {
                if let error { a2aLog.error("[A2A] Recv error: \(error)") }
                return
            }
            Task { await self.processHTTPRequest(data: data, connection: connection, id: id) }
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection, id: UUID) async {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, statusCode: 400, body: "Invalid encoding")
            return
        }

        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerSection = parts.first ?? ""
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : ""
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, statusCode: 400, body: "Malformed request")
            return
        }
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else {
            sendHTTPResponse(connection: connection, statusCode: 400, body: "Malformed request line")
            return
        }
        let method = String(tokens[0])
        let pathRaw = String(tokens[1])

        switch (method, pathRaw) {
        case ("POST", _) where pathRaw.hasPrefix("/ai-to-ai") && !pathRaw.hasPrefix("/ai-to-ai/"):
            await handleTaskExecution(body: body, connection: connection)

        case ("GET", _) where pathRaw.hasPrefix("/ai-to-ai/status"):
            handleStatusCheck(connection: connection)

        case ("OPTIONS", _):
            sendHTTPResponse(connection: connection, statusCode: 200, body: "",
                             extraHeaders: corsHeaders())

        default:
            sendHTTPResponse(connection: connection, statusCode: 404, body: "Not found")
        }
    }

    // MARK: - Task Execution

    private func handleTaskExecution(body: String, connection: NWConnection) async {
        let requestId = UUID().uuidString

        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let task = json["task"] as? String, !task.isEmpty else {
            sendJSONResponse(connection: connection, statusCode: 400, json: [
                "status": "error",
                "error": "Invalid request — must include non-empty 'task' field",
                "request_id": requestId
            ])
            return
        }

        let context = json["context"] as? String

        guard let handler = onRequest else {
            sendJSONResponse(connection: connection, statusCode: 503, json: [
                "status": "error",
                "error": "AI-to-AI server not yet wired to AppState",
                "request_id": requestId
            ])
            return
        }

        let startTime = Date()
        let fullInput = context.map { "Context: \($0)\n\nTask: \(task)" } ?? task

        // Bridge callback to async with 600s timeout
        let response: String = await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func safeResume(_ value: String) {
                let alreadyResumed = resumed.withLock { val -> Bool in
                    if val { return true }
                    val = true
                    return false
                }
                guard !alreadyResumed else { return }
                cont.resume(returning: value)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
                safeResume("Error: request timed out after 600s")
            }

            handler(fullInput) { result in
                safeResume(result)
            }
        }

        let executionMs = Int(Date().timeIntervalSince(startTime) * 1000)

        sendJSONResponse(connection: connection, statusCode: 200, json: [
            "status": "success",
            "result": response,
            "execution_time_ms": executionMs,
            "request_id": requestId
        ])
    }

    // MARK: - Status

    private func handleStatusCheck(connection: NWConnection) {
        sendJSONResponse(connection: connection, statusCode: 200, json: [
            "status": "ok",
            "port": Int(port),
            "connections": connections.count
        ])
    }

    // MARK: - HTTP Helpers

    private func sendHTTPResponse(connection: NWConnection, statusCode: Int, body: String,
                                  contentType: String = "text/plain", extraHeaders: [String] = []) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var header = "HTTP/1.1 \(statusCode) \(httpStatusText(statusCode))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        for h in extraHeaders { header += "\(h)\r\n" }
        header += "\r\n"

        var fullData = header.data(using: .utf8) ?? Data()
        fullData.append(bodyData)
        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONResponse(connection: NWConnection, statusCode: Int, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, statusCode: 500, body: "Serialization error")
            return
        }
        sendHTTPResponse(connection: connection, statusCode: statusCode, body: str,
                         contentType: "application/json", extraHeaders: corsHeaders())
    }

    private func corsHeaders() -> [String] {
        [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type, Authorization"
        ]
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}
