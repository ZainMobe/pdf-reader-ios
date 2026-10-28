import Foundation
import OSLog

nonisolated private let claudeLog = Logger(subsystem: "com.pdfreader.ai", category: "Claude")

struct ClaudeAI: AIGenerator {
    static let defaultModel = "claude-haiku-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let maxOutputTokens = 2_048

    let backend: AIBackend = .cloud
    let apiKey: String
    let model: String

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        let configured = (Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_MODEL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let model {
            self.model = model
        } else if !configured.isEmpty, !configured.hasPrefix("$(") {
            self.model = configured
        } else {
            self.model = Self.defaultModel
        }
    }

    struct Turn: Sendable {
        let role: String
        let text: String
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        let body = Self.body(model: model, system: instructions, turns: [Turn(role: "user", text: prompt)],
                             stream: false, cacheSystem: false, tool: nil)
        let json = try await Self.send(body: body, apiKey: apiKey)
        if let reason = json["stop_reason"] as? String, reason == "refusal" { throw AIError.refused }
        return Self.text(from: json)
    }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let body = Self.body(model: model, system: instructions, turns: [Turn(role: "user", text: prompt)],
                             stream: true, cacheSystem: false, tool: nil)
        return Self.stream(body: body, apiKey: apiKey, onComplete: nil)
    }

    func respond<T: AIStructured>(instructions: String, prompt: String, generating: T.Type) async throws -> T {
        let tool: [String: Any] = [
            "name": "record",
            "description": "Record the extracted result. Always call this tool exactly once.",
            "input_schema": T.jsonSchema,
        ]
        let body = Self.body(model: model, system: instructions, turns: [Turn(role: "user", text: prompt)],
                             stream: false, cacheSystem: false, tool: tool)
        let json = try await Self.send(body: body, apiKey: apiKey)
        if let reason = json["stop_reason"] as? String, reason == "refusal" { throw AIError.refused }
        guard let blocks = json["content"] as? [[String: Any]],
              let block = blocks.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = block["input"],
              JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input)
        else { throw AIError.decodingFailed }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            claudeLog.error("structured decode failed: \(String(describing: error), privacy: .public)")
            throw AIError.decodingFailed
        }
    }

    func makeChat(instructions: String) -> any AIChatSession {
        ClaudeChatSession(apiKey: apiKey, model: model, instructions: instructions)
    }

    static func body(model: String, system: String, turns: [Turn], stream: Bool, cacheSystem: Bool,
                     tool: [String: Any]?) -> [String: Any] {
        var systemBlock: [String: Any] = ["type": "text", "text": system]
        if cacheSystem { systemBlock["cache_control"] = ["type": "ephemeral"] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxOutputTokens,
            "system": [systemBlock],
            "messages": turns.map { ["role": $0.role, "content": $0.text] },
            "stream": stream,
        ]
        if let tool {
            body["tools"] = [tool]
            body["tool_choice"] = ["type": "tool", "name": tool["name"] ?? "record"]
        }
        return body
    }

    static func makeRequest(body: [String: Any], apiKey: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func send(body: [String: Any], apiKey: String) async throws -> [String: Any] {
        let request = try makeRequest(body: body, apiKey: apiKey, timeout: 90)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let error = apiError(status: status, data: data)
                    if attempt == 1, case .busy = error {
                        try await Task.sleep(for: .seconds(1.5))
                        continue
                    }
                    throw error
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AIError.decodingFailed
                }
                return json
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIError {
                throw error
            } catch {
                throw AIError.from(error)
            }
        }
    }

    static func stream(body: [String: Any], apiKey: String,
                       onComplete: (@Sendable (String) -> Void)?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var accumulated = ""
                do {
                    let request = try makeRequest(body: body, apiKey: apiKey, timeout: 180)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        throw apiError(status: status, data: raw)
                    }
                    var stopReason: String?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String
                        else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               (delta["type"] as? String) == "text_delta",
                               let text = delta["text"] as? String {
                                accumulated += text
                                continuation.yield(accumulated)
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any] {
                                stopReason = delta["stop_reason"] as? String
                            }
                        case "error":
                            let info = event["error"] as? [String: Any]
                            throw mapAPIError(status: 0, type: info?["type"] as? String,
                                              message: info?["message"] as? String ?? "Unknown error")
                        default:
                            break
                        }
                    }
                    if stopReason == "refusal", accumulated.isEmpty { throw AIError.refused }
                    onComplete?(accumulated)
                    continuation.finish()
                } catch is CancellationError {
                    if !accumulated.isEmpty { onComplete?(accumulated) }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func text(from json: [String: Any]) -> String {
        guard let blocks = json["content"] as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    static func apiError(status: Int, data: Data) -> AIError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let info = json?["error"] as? [String: Any]
        let message = info?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        claudeLog.error("HTTP \(status): \(message, privacy: .public)")
        return mapAPIError(status: status, type: info?["type"] as? String, message: message)
    }

    static func mapAPIError(status: Int, type: String?, message: String) -> AIError {
        switch type {
        case "rate_limit_error", "overloaded_error": return .busy
        case "authentication_error", "permission_error": return .server(status: 401, message: message)
        default: break
        }
        if status == 429 || status == 529 { return .busy }
        if message.localizedCaseInsensitiveContains("too long") || message.localizedCaseInsensitiveContains("context") {
            return .contextTooLong
        }
        return .server(status: status, message: message)
    }
}

final class ClaudeChatSession: AIChatSession, @unchecked Sendable {
    let backend: AIBackend = .cloud
    private let apiKey: String
    private let model: String
    private let instructions: String
    private let lock = NSLock()
    private var turns: [ClaudeAI.Turn] = []

    init(apiKey: String, model: String, instructions: String) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
    }

    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let history = turns + [ClaudeAI.Turn(role: "user", text: prompt)]
        lock.unlock()
        let body = ClaudeAI.body(model: model, system: instructions, turns: history,
                                 stream: true, cacheSystem: true, tool: nil)
        return ClaudeAI.stream(body: body, apiKey: apiKey) { [weak self] reply in
            guard let self, !reply.isEmpty else { return }
            self.lock.lock()
            self.turns = history + [ClaudeAI.Turn(role: "assistant", text: reply)]
            self.lock.unlock()
        }
    }

    func reset() {
        lock.lock()
        turns = []
        lock.unlock()
    }
}
