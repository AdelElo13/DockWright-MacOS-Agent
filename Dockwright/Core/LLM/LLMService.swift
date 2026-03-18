import Foundation
import os

private let llmLog = Logger(subsystem: "com.Aatje.Dockwright", category: "LLM")

// LLMProvider, LLMModelInfo, and LLMModels are defined in LLMModels.swift

/// Multi-provider streaming LLM client.
/// Supports Anthropic, OpenAI, Google Gemini, xAI, Mistral, DeepSeek, Kimi, and Ollama.
/// Uses `URLSession.bytes(for:)` for SSE parsing — no AsyncStream.
final class LLMService: @unchecked Sendable {
    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30   // 30s connection timeout
        config.timeoutIntervalForResource = 180 // 180s total streaming timeout
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Anthropic Auth Helpers

    /// Whether the given key is a regular Anthropic API key (sk-ant-api...).
    /// Claude Code OAuth tokens start with sk-ant-oat → must use Bearer, NOT x-api-key.
    nonisolated static func isApiKey(_ apiKey: String) -> Bool {
        guard apiKey.hasPrefix("sk-") else { return false }
        if apiKey.hasPrefix("sk-ant-oat") { return false }
        return true
    }

    /// Whether the given API key is an OAuth/Bearer token (needs oauth-2025-04-20 beta header).
    nonisolated static func isOAuthToken(_ apiKey: String) -> Bool {
        !apiKey.isEmpty && !isApiKey(apiKey)
    }

    /// Applies the correct auth headers for Anthropic API calls.
    /// API keys use x-api-key; OAuth tokens use Authorization: Bearer.
    private func applyAnthropicAuth(_ request: inout URLRequest, apiKey: String) {
        if Self.isApiKey(apiKey) {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "x-api-key")
        }
    }

    // MARK: - Streaming Chat (Multi-Provider Router)

    func streamChat(
        messages: [LLMMessage],
        tools: [[String: Any]]? = nil,
        model: String = "claude-opus-4-6",
        apiKey: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> LLMResponse {
        // Single attempt — retry logic lives in AppState.runLLMLoop() to avoid double-retry.
        return try await _streamChatOnce(
            messages: messages, tools: tools, model: model,
            apiKey: apiKey, systemPrompt: systemPrompt,
            temperature: temperature, maxTokens: maxTokens,
            onChunk: onChunk
        )
    }

    private func _streamChatOnce(
        messages: [LLMMessage],
        tools: [[String: Any]]? = nil,
        model: String = "claude-opus-4-6",
        apiKey: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> LLMResponse {
        let provider = LLMModels.provider(for: model)
        let resolvedTemp = temperature
        let resolvedMaxTokens = maxTokens ?? 8192

        return try await withThrowingTaskGroup(of: LLMResponse.self) { group in
            // Watchdog timeout
            group.addTask {
                try await Task.sleep(nanoseconds: 180_000_000_000)
                throw LLMError.timeout
            }

            // Provider-specific stream
            group.addTask { [self] in
                switch provider {
                case .anthropic:
                    return try await self.performAnthropicStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk
                    )
                case .openai:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "https://api.openai.com/v1/chat/completions"
                    )
                case .ollama:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: "", systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "http://localhost:11434/v1/chat/completions"
                    )
                case .google:
                    return try await self.performGeminiStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk
                    )
                case .xai:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "https://api.x.ai/v1/chat/completions"
                    )
                case .mistral:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "https://api.mistral.ai/v1/chat/completions"
                    )
                case .deepseek:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "https://api.deepseek.com/chat/completions"
                    )
                case .kimi:
                    return try await self.performOpenAIStream(
                        messages: messages, tools: tools, model: model,
                        apiKey: apiKey, systemPrompt: systemPrompt,
                        temperature: resolvedTemp, maxTokens: resolvedMaxTokens,
                        onChunk: onChunk,
                        baseURL: "https://api.moonshot.cn/v1/chat/completions"
                    )
                }
            }

            guard let result = try await group.next() else {
                throw LLMError.invalidResponse
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Ollama Model Discovery

    /// Fetch available models from Ollama (if running).
    func fetchOllamaModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { $0["name"] as? String }
            }
        } catch {
            // Ollama not running
        }
        return []
    }

    // MARK: - Anthropic SSE Stream

    // MARK: - Model-Aware Max Tokens

    /// Returns the correct max_tokens for a given Anthropic model.
    /// Matches the values from Jarvis: Opus 4.6=128K, Sonnet 4.6/4.5=64K, Opus 4=32K, others=64K.
    private func anthropicMaxTokens(for model: String, userMax: Int) -> Int {
        // Use the larger of model capability and user request
        let modelMax: Int
        if model.contains("opus-4-6") { modelMax = 128000 }
        else if model.contains("opus-4-5") || model.contains("sonnet-4-6") || model.contains("sonnet-4-5") { modelMax = 64000 }
        else if model.contains("opus-4") { modelMax = 32000 }
        else { modelMax = 64000 } // Sonnet/Haiku 4.x all support 64K
        // Clamp user setting: at least 256 tokens, at most model max
        return min(max(userMax, 256), modelMax)
    }

    private func performAnthropicStream(
        messages: [LLMMessage],
        tools: [[String: Any]]?,
        model: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double? = nil,
        maxTokens: Int = 8192,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> LLMResponse {
        // Trim whitespace from API key (critical — trailing newlines break auth detection)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMError.apiError("Anthropic API key is empty")
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.apiError("Invalid Anthropic API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 200

        // Apply correct auth: API key → x-api-key, OAuth → Authorization: Bearer
        applyAnthropicAuth(&request, apiKey: trimmedKey)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isOAuth = Self.isOAuthToken(trimmedKey)

        // Detect thinking-capable models
        let isAdaptiveModel = model.contains("opus-4-6") || model.contains("sonnet-4-6")
        let isLegacyThinkingModel = !isAdaptiveModel && (model.contains("opus-4") || model.contains("sonnet-4-5"))
        let hasTools = tools != nil && !tools!.isEmpty
        // OAuth + thinking + tools is not yet supported — disable thinking when tools are present with OAuth
        let useThinking = (isAdaptiveModel || isLegacyThinkingModel) && !(isOAuth && hasTools)

        // Beta headers
        var betaParts: [String] = []
        if isOAuth { betaParts.append("oauth-2025-04-20") }
        // Legacy thinking models need interleaved-thinking header; adaptive models don't
        if useThinking && isLegacyThinkingModel { betaParts.append("interleaved-thinking-2025-05-14") }
        if !isOAuth { betaParts.append("prompt-caching-2024-07-31") }
        request.setValue(betaParts.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")

        // Model-aware max tokens (opus supports much more than 8192)
        let effectiveMaxTokens = anthropicMaxTokens(for: model, userMax: maxTokens)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": effectiveMaxTokens,
            "stream": true,
        ]
        if let temperature, !useThinking, !isOAuth { body["temperature"] = temperature }

        // Thinking configuration
        if useThinking {
            if isAdaptiveModel {
                // Opus 4.6 / Sonnet 4.6: use adaptive thinking (no budget_tokens needed)
                body["thinking"] = ["type": "adaptive"] as [String: String]
            } else {
                // Legacy thinking models: manual thinking with budget
                let thinkingBudget = max(1024, effectiveMaxTokens / 2)
                body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget] as [String: Any]
            }
        }

        // Build system prompt blocks
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if isOAuth {
            // OAuth requests: build system blocks with attribution header for full model access
            var systemBlocks: [[String: Any]] = []

            // Attribution header — required for OAuth tokens to access premium models (opus, sonnet)
            let billingHeader = "x-anthropic-billing-header: cc_version=2.1.66; cc_entrypoint=dockwright;"
            systemBlocks.append(["type": "text", "text": billingHeader])

            if !trimmedPrompt.isEmpty {
                systemBlocks.append(["type": "text", "text": trimmedPrompt])
            }

            body["system"] = systemBlocks
        } else if !trimmedPrompt.isEmpty {
            // API key: use system field with cache_control for prompt caching
            body["system"] = [
                ["type": "text", "text": trimmedPrompt, "cache_control": ["type": "ephemeral"]]
            ] as [[String: Any]]
        }

        body["messages"] = buildAnthropicMessages(messages)

        // Tools
        if var toolDefs = tools, !toolDefs.isEmpty {
            // Only add cache_control on tools for non-OAuth (prompt caching)
            if !isOAuth, var lastTool = toolDefs.last {
                lastTool["cache_control"] = ["type": "ephemeral"] as [String: String]
                toolDefs[toolDefs.count - 1] = lastTool
            }
            body["tools"] = toolDefs
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData
        let toolCount = (tools?.count ?? 0)
        let authType = isOAuth ? "OAuth" : "API-key"
        llmLog.debug("[Anthropic] model=\(model) auth=\(authType) tools=\(toolCount) bytes=\(jsonData.count)")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 2000 { break } }
            llmLog.warning("[Anthropic] HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
            if httpResponse.statusCode == 401 { throw LLMError.unauthorized }
            if httpResponse.statusCode == 429 { throw LLMError.rateLimited }
            if httpResponse.statusCode >= 500 {
                throw LLMError.serverError(httpResponse.statusCode)
            }
            throw LLMError.apiError("HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
        }

        var fullText = ""
        var inputTokens = 0
        var outputTokens = 0
        var finishReason: String?
        var thinkingContent = ""

        struct AnthropicToolBlock {
            var id: String
            var name: String
            var arguments: String
        }
        var currentToolBlocks: [AnthropicToolBlock] = []
        var activeToolIndex: Int?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" { break }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else { continue }

            switch eventType {
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    inputTokens = input
                }

            case "content_block_start":
                if let contentBlock = json["content_block"] as? [String: Any] {
                    let blockType = contentBlock["type"] as? String ?? ""
                    if blockType == "tool_use" {
                        let id = contentBlock["id"] as? String ?? UUID().uuidString
                        let name = contentBlock["name"] as? String ?? "unknown"
                        currentToolBlocks.append(AnthropicToolBlock(id: id, name: name, arguments: ""))
                        activeToolIndex = currentToolBlocks.count - 1
                        onChunk(.toolStarted(name))
                        onChunk(.activity(.executing(name)))
                    } else if blockType == "thinking" {
                        onChunk(.activity(.thinking))
                    }
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String ?? ""
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        fullText += text
                        onChunk(.textDelta(text))
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        if let idx = activeToolIndex {
                            currentToolBlocks[idx].arguments += partial
                        }
                    } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                        thinkingContent += thinking
                        onChunk(.thinking(thinking))
                    }
                }

            case "content_block_stop":
                activeToolIndex = nil

            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    finishReason = delta["stop_reason"] as? String
                }
                if let usage = json["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    outputTokens = output
                }

            default:
                break
            }
        }

        let toolCalls: [ToolCall]? = currentToolBlocks.isEmpty ? nil : currentToolBlocks.map { block in
            var args = block.arguments
            if !args.isEmpty, (try? JSONSerialization.jsonObject(with: Data(args.utf8))) == nil {
                for suffix in ["}", "}}", "\"}", "\"}}", "\"]}", "\"]}}" ] {
                    let candidate = args + suffix
                    if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil {
                        args = candidate
                        break
                    }
                }
            }
            return ToolCall(id: block.id, type: "function", function: ToolCallFunction(name: block.name, arguments: args))
        }
        let doneText = fullText.isEmpty ? (toolCalls != nil ? "[tool_use]" : "") : fullText
        onChunk(.done(doneText))

        return LLMResponse(
            content: fullText.isEmpty ? nil : fullText,
            toolCalls: toolCalls,
            finishReason: finishReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingContent: thinkingContent.isEmpty ? nil : thinkingContent
        )
    }

    // MARK: - OpenAI / Ollama SSE Stream

    private func performOpenAIStream(
        messages: [LLMMessage],
        tools: [[String: Any]]?,
        model: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double? = nil,
        maxTokens: Int = 8192,
        onChunk: @escaping @Sendable (StreamChunk) -> Void,
        baseURL: String
    ) async throws -> LLMResponse {
        guard let url = URL(string: baseURL) else {
            throw LLMError.apiError("Invalid API URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": maxTokens,
        ]
        if let temperature { body["temperature"] = temperature }

        // Build OpenAI-format messages (system + user/assistant/tool)
        body["messages"] = buildOpenAIMessages(messages, systemPrompt: systemPrompt)

        // Convert tools to OpenAI format
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool["name"] as? String ?? "",
                        "description": tool["description"] as? String ?? "",
                        "parameters": tool["input_schema"] ?? [:],
                    ] as [String: Any]
                ] as [String: Any]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 2000 { break } }
            if httpResponse.statusCode == 401 { throw LLMError.unauthorized }
            if httpResponse.statusCode == 429 { throw LLMError.rateLimited }
            if httpResponse.statusCode >= 500 {
                throw LLMError.serverError(httpResponse.statusCode)
            }
            throw LLMError.apiError("HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
        }

        var fullText = ""
        var inputTokens = 0
        var outputTokens = 0
        var finishReason: String?

        // OpenAI tool call accumulation
        struct OAIToolCall {
            var id: String
            var name: String
            var arguments: String
        }
        var toolCallAccum: [Int: OAIToolCall] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" { break }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Usage (OpenAI includes it in the final chunk)
            if let usage = json["usage"] as? [String: Any] {
                inputTokens = usage["prompt_tokens"] as? Int ?? 0
                outputTokens = usage["completion_tokens"] as? Int ?? 0
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let fr = choice["finish_reason"] as? String {
                finishReason = fr
            }

            guard let delta = choice["delta"] as? [String: Any] else { continue }

            // Text content
            if let content = delta["content"] as? String {
                fullText += content
                onChunk(.textDelta(content))
            }

            // Reasoning content (DeepSeek reasoner emits this field)
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                onChunk(.thinking(reasoning))
            }

            // Tool calls
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let index = tc["index"] as? Int ?? 0
                    if let id = tc["id"] as? String {
                        let fn = tc["function"] as? [String: Any]
                        let name = fn?["name"] as? String ?? ""
                        toolCallAccum[index] = OAIToolCall(id: id, name: name, arguments: "")
                        onChunk(.toolStarted(name))
                        onChunk(.activity(.executing(name)))
                    }
                    if let fn = tc["function"] as? [String: Any],
                       let args = fn["arguments"] as? String {
                        toolCallAccum[index, default: OAIToolCall(id: "", name: "", arguments: "")].arguments += args
                    }
                }
            }
        }

        // Build tool calls
        let toolCalls: [ToolCall]? = toolCallAccum.isEmpty ? nil : toolCallAccum.sorted(by: { $0.key < $1.key }).map { _, tc in
            var args = tc.arguments
            if !args.isEmpty, (try? JSONSerialization.jsonObject(with: Data(args.utf8))) == nil {
                for suffix in ["}", "}}", "\"}", "\"}}", "\"]}", "\"]}}" ] {
                    let candidate = args + suffix
                    if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil {
                        args = candidate
                        break
                    }
                }
            }
            return ToolCall(
                id: tc.id,
                type: "function",
                function: ToolCallFunction(name: tc.name, arguments: args)
            )
        }

        let doneText = fullText.isEmpty ? (toolCalls != nil ? "[tool_use]" : "") : fullText
        onChunk(.done(doneText))

        return LLMResponse(
            content: fullText.isEmpty ? nil : fullText,
            toolCalls: toolCalls,
            finishReason: finishReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingContent: nil
        )
    }

    // MARK: - Message Conversion (Anthropic)

    private func buildAnthropicMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for msg in messages {
            if msg.role == "system" { continue }
            var entry: [String: Any] = ["role": msg.role == "tool" ? "user" : msg.role]

            if msg.role == "tool" {
                entry["content"] = [[
                    "type": "tool_result",
                    "tool_use_id": msg.toolCallId ?? "",
                    "content": msg.content ?? ""
                ]]
            } else if msg.role == "assistant", let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                var contentBlocks: [[String: Any]] = []
                if let text = msg.content, !text.isEmpty {
                    contentBlocks.append(["type": "text", "text": text])
                }
                for tc in toolCalls {
                    var toolBlock: [String: Any] = [
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.function.name,
                    ]
                    if let args = try? JSONSerialization.jsonObject(with: Data(tc.function.arguments.utf8)) {
                        toolBlock["input"] = args
                    } else {
                        toolBlock["input"] = [String: String]()
                    }
                    contentBlocks.append(toolBlock)
                }
                entry["content"] = contentBlocks
            } else if let images = msg.images, !images.isEmpty {
                var contentBlocks: [[String: Any]] = []
                for img in images {
                    contentBlocks.append([
                        "type": "image",
                        "source": [
                            "type": img.type,
                            "media_type": img.mediaType,
                            "data": img.data
                        ]
                    ])
                }
                if let text = msg.content, !text.isEmpty {
                    contentBlocks.append(["type": "text", "text": text])
                }
                entry["content"] = contentBlocks
            } else {
                entry["content"] = msg.content ?? ""
            }

            result.append(entry)
        }

        return result
    }

    // MARK: - Message Conversion (OpenAI / Ollama)

    private func buildOpenAIMessages(_ messages: [LLMMessage], systemPrompt: String) -> [[String: Any]] {
        var result: [[String: Any]] = []

        if !systemPrompt.isEmpty {
            result.append(["role": "system", "content": systemPrompt])
        }

        for msg in messages {
            if msg.role == "system" { continue }

            if msg.role == "tool" {
                result.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallId ?? "",
                    "content": msg.content ?? ""
                ])
            } else if msg.role == "assistant", let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                var entry: [String: Any] = ["role": "assistant"]
                if let text = msg.content, !text.isEmpty {
                    entry["content"] = text
                }
                entry["tool_calls"] = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.function.name,
                            "arguments": tc.function.arguments
                        ] as [String: Any]
                    ] as [String: Any]
                }
                result.append(entry)
            } else {
                result.append([
                    "role": msg.role,
                    "content": msg.content ?? ""
                ])
            }
        }

        return result
    }

}

// MARK: - Errors

enum LLMError: LocalizedError {
    case timeout
    case invalidResponse
    case unauthorized
    case rateLimited
    case apiError(String)
    case noAPIKey
    case noInternet
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Request timed out after 180 seconds. The API may be slow -- try again."
        case .invalidResponse: return "Invalid response from API"
        case .unauthorized: return "Invalid API key. Check Settings > API Keys."
        case .rateLimited: return "Rate limited by API. Please wait a moment and try again."
        case .apiError(let msg): return msg
        case .noAPIKey: return "No API key configured. Go to Settings > API Keys."
        case .noInternet: return "No internet connection. Check your network and try again."
        case .serverError(let code): return "API server error (HTTP \(code)). Try again in a moment."
        }
    }

    /// Whether this error is retryable
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .serverError: return true
        default: return false
        }
    }
}

// MARK: - Google Gemini SSE Stream

extension LLMService {
    /// Stream chat completions from Google Gemini API.
    /// Uses SSE streaming via `?alt=sse` query parameter.
    func performGeminiStream(
        messages: [LLMMessage],
        tools: [[String: Any]]?,
        model: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double? = nil,
        maxTokens: Int = 8192,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> LLMResponse {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            throw LLMError.apiError("Invalid Gemini API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 180

        // Build Gemini request body
        var body: [String: Any] = [:]

        // System instruction
        if !systemPrompt.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": systemPrompt]]
            ]
        }

        // Build contents array
        var contents: [[String: Any]] = []
        for msg in messages {
            if msg.role == "system" || msg.role == "tool" { continue }

            let geminiRole: String
            switch msg.role {
            case "user":     geminiRole = "user"
            case "assistant": geminiRole = "model"
            default:         continue
            }

            var parts: [[String: Any]] = []
            if let text = msg.content, !text.isEmpty {
                parts.append(["text": text])
            }
            if let images = msg.images {
                for img in images {
                    parts.append([
                        "inlineData": [
                            "mimeType": img.mediaType,
                            "data": img.data
                        ]
                    ])
                }
            }

            if !parts.isEmpty {
                contents.append(["role": geminiRole, "parts": parts])
            }
        }
        body["contents"] = contents

        // Generation config
        var genConfig: [String: Any] = ["maxOutputTokens": maxTokens]
        if let temperature { genConfig["temperature"] = temperature }
        body["generationConfig"] = genConfig

        // Convert tools to Gemini format
        if let tools, !tools.isEmpty {
            let geminiFuncs = tools.map { tool -> [String: Any] in
                var params = tool["input_schema"] as? [String: Any] ?? [:]
                params.removeValue(forKey: "additionalProperties")
                return [
                    "name": tool["name"] as? String ?? "",
                    "description": tool["description"] as? String ?? "",
                    "parameters": params
                ] as [String: Any]
            }
            body["tools"] = [["functionDeclarations": geminiFuncs]]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }

        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 2000 { break } }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 { throw LLMError.unauthorized }
            if httpResponse.statusCode == 429 { throw LLMError.rateLimited }
            if httpResponse.statusCode >= 500 {
                throw LLMError.serverError(httpResponse.statusCode)
            }
            throw LLMError.apiError("Gemini HTTP \(httpResponse.statusCode): \(errorBody.prefix(500))")
        }

        var fullText = ""
        var inputTokens = 0
        var outputTokens = 0
        var finishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" { break }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first {
                if let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String {
                            fullText += text
                            onChunk(.textDelta(text))
                        }
                    }
                }
                if let fr = firstCandidate["finishReason"] as? String {
                    finishReason = fr
                }
            }

            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                inputTokens = usageMetadata["promptTokenCount"] as? Int ?? inputTokens
                outputTokens = usageMetadata["candidatesTokenCount"] as? Int ?? outputTokens
            }
        }

        onChunk(.done(fullText.isEmpty ? "" : fullText))

        return LLMResponse(
            content: fullText.isEmpty ? nil : fullText,
            toolCalls: nil,
            finishReason: finishReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingContent: nil
        )
    }
}
