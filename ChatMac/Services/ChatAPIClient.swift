import Foundation

struct ChatRequestMessage: Codable, Sendable {
    let role: String
    let content: String

    init(role: MessageRole, content: String) {
        self.role = role.rawValue
        self.content = content
    }
}

struct ChatModelTarget: Sendable {
    let modelIdentifier: String
    let displayName: String
    let provider: AIProviderKind
    let baseURLString: String
    let keychainAccount: String
}

struct ChatCompletionResult: Sendable {
    let content: String
    let model: String?
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

enum ChatStreamEvent: Sendable {
    case delta(String)
    case completed(ChatCompletionResult)
}

struct ChatService {
    private let keychain: KeychainService
    private let client: ChatAPIClient

    init(
        keychain: KeychainService = KeychainService(),
        client: ChatAPIClient = ChatAPIClient()
    ) {
        self.keychain = keychain
        self.client = client
    }

    func complete(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        maxTokens: Int = 4096
    ) async throws -> ChatCompletionResult {
        let storedKey = try keychain.read(account: target.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = storedKey.flatMap { $0.isEmpty ? nil : $0 }

        return try await client.complete(
            messages: messages,
            target: target,
            apiKey: apiKey,
            maxTokens: maxTokens
        )
    }

    func stream(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        maxTokens: Int = 4096
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let storedKey = try keychain.read(account: target.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = storedKey.flatMap { $0.isEmpty ? nil : $0 }

        return try client.stream(
            messages: messages,
            target: target,
            apiKey: apiKey,
            maxTokens: maxTokens
        )
    }
}

struct ChatAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func complete(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) async throws -> ChatCompletionResult {
        switch target.provider {
        case .openAICompatible:
            try await completeOpenAI(
                messages: messages,
                target: target,
                apiKey: apiKey,
                maxTokens: maxTokens
            )
        case .anthropicCompatible:
            try await completeAnthropic(
                messages: messages,
                target: target,
                apiKey: apiKey,
                maxTokens: maxTokens
            )
        }
    }

    func stream(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        switch target.provider {
        case .openAICompatible:
            try streamOpenAI(
                messages: messages,
                target: target,
                apiKey: apiKey,
                maxTokens: maxTokens
            )
        case .anthropicCompatible:
            try streamAnthropic(
                messages: messages,
                target: target,
                apiKey: apiKey,
                maxTokens: maxTokens
            )
        }
    }

    private func streamOpenAI(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let endpoint = try endpointURL(
            from: target.baseURLString,
            appending: "chat/completions"
        )
        let payload = OpenAIChatCompletionRequest(
            model: target.modelIdentifier,
            messages: messages,
            temperature: 0.75,
            maxTokens: maxTokens,
            stream: true
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await streamingBytes(for: request)
                    var content = ""
                    var model: String?
                    var usage: OpenAIChatCompletionResponse.Usage?

                    try await consumeServerSentEvents(bytes) { _, data in
                        guard data != "[DONE]" else { return }
                        let chunkData = Data(data.utf8)
                        if let error = streamingError(in: chunkData) {
                            throw ChatAPIError.streaming(error)
                        }
                        guard let chunk = openAIStreamDelta(in: chunkData) else {
                            return
                        }
                        model = chunk.model ?? model
                        usage = chunk.usage ?? usage
                        let delta = chunk.text
                        guard !delta.isEmpty else { return }
                        content.append(delta)
                        continuation.yield(.delta(delta))
                    }

                    let finalContent = try validatedContent(content)
                    continuation.yield(
                        .completed(
                            ChatCompletionResult(
                                content: finalContent,
                                model: model,
                                promptTokens: usage?.promptTokens,
                                completionTokens: usage?.completionTokens,
                                totalTokens: usage?.totalTokens
                            )
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamAnthropic(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let endpoint = try endpointURL(
            from: target.baseURLString,
            appending: "messages"
        )
        let system = messages
            .filter { $0.role == MessageRole.system.rawValue }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let conversationMessages = messages.filter {
            $0.role == MessageRole.user.rawValue || $0.role == MessageRole.assistant.rawValue
        }
        let payload = AnthropicMessagesRequest(
            model: target.modelIdentifier,
            system: system.isEmpty ? nil : system,
            messages: conversationMessages,
            temperature: 0.75,
            maxTokens: maxTokens,
            stream: true
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await streamingBytes(for: request)
                    var content = ""
                    var model: String?
                    var inputUsage: AnthropicStreamEvent.Usage?
                    var outputUsage: AnthropicStreamEvent.Usage?

                    try await consumeServerSentEvents(bytes) { _, data in
                        let eventData = Data(data.utf8)
                        if let error = streamingError(in: eventData) {
                            throw ChatAPIError.streaming(error)
                        }
                        let event: AnthropicStreamEvent
                        do {
                            event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: eventData)
                        } catch {
                            throw ChatAPIError.invalidPayload(error.localizedDescription)
                        }
                        model = event.message?.model ?? model
                        inputUsage = event.message?.usage ?? inputUsage
                        outputUsage = event.usage ?? outputUsage
                        guard event.type == "content_block_delta",
                              let delta = event.delta?.text,
                              !delta.isEmpty else { return }
                        content.append(delta)
                        continuation.yield(.delta(delta))
                    }

                    let finalContent = try validatedContent(content)
                    let promptTokens = inputUsage?.promptTokens
                    let completionTokens = outputUsage?.outputTokens
                    continuation.yield(
                        .completed(
                            ChatCompletionResult(
                                content: finalContent,
                                model: model,
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                totalTokens: sum(promptTokens, completionTokens)
                            )
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func completeOpenAI(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) async throws -> ChatCompletionResult {
        let endpoint = try endpointURL(
            from: target.baseURLString,
            appending: "chat/completions"
        )
        let payload = OpenAIChatCompletionRequest(
            model: target.modelIdentifier,
            messages: messages,
            temperature: 0.75,
            maxTokens: maxTokens,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await perform(request)

        let decoded: OpenAIChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        } catch {
            throw ChatAPIError.invalidPayload(error.localizedDescription)
        }

        guard let firstChoice = decoded.choices.first else {
            throw ChatAPIError.missingChoices
        }
        let content = try validatedContent(firstChoice.message.content.text)

        return ChatCompletionResult(
            content: content,
            model: decoded.model,
            promptTokens: decoded.usage?.promptTokens,
            completionTokens: decoded.usage?.completionTokens,
            totalTokens: decoded.usage?.totalTokens
        )
    }

    private func completeAnthropic(
        messages: [ChatRequestMessage],
        target: ChatModelTarget,
        apiKey: String?,
        maxTokens: Int
    ) async throws -> ChatCompletionResult {
        let endpoint = try endpointURL(
            from: target.baseURLString,
            appending: "messages"
        )
        let system = messages
            .filter { $0.role == MessageRole.system.rawValue }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let conversationMessages = messages.filter {
            $0.role == MessageRole.user.rawValue || $0.role == MessageRole.assistant.rawValue
        }
        let payload = AnthropicMessagesRequest(
            model: target.modelIdentifier,
            system: system.isEmpty ? nil : system,
            messages: conversationMessages,
            temperature: 0.75,
            maxTokens: maxTokens,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await perform(request)

        let decoded: AnthropicMessagesResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        } catch {
            throw ChatAPIError.invalidPayload(error.localizedDescription)
        }

        let content = try validatedContent(decoded.content.text)
        return ChatCompletionResult(
            content: content,
            model: decoded.model,
            promptTokens: decoded.usage?.promptTokens,
            completionTokens: decoded.usage?.outputTokens,
            totalTokens: decoded.usage?.totalTokens
        )
    }

    private func streamingBytes(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let data = try await collectData(from: bytes)
            throw ChatAPIError.httpStatus(
                httpResponse.statusCode,
                parseErrorMessage(from: data, statusCode: httpResponse.statusCode)
            )
        }
        return bytes
    }

    private func consumeServerSentEvents(
        _ bytes: URLSession.AsyncBytes,
        onEvent: (String?, String) throws -> Void
    ) async throws {
        var eventName: String?
        var dataLines: [String] = []

        func emitEvent() throws {
            guard !dataLines.isEmpty else {
                eventName = nil
                return
            }
            try onEvent(eventName, dataLines.joined(separator: "\n"))
            eventName = nil
            dataLines = []
        }

        for try await rawLine in bytes.lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                try emitEvent()
            } else if line.hasPrefix("event:") {
                eventName = line.dropFirst("event:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                // AsyncBytes.lines may omit blank SSE separators, so a new data line
                // also marks the end of the preceding single-line JSON event.
                if !dataLines.isEmpty {
                    try emitEvent()
                }
                var dataLine = String(line.dropFirst("data:".count))
                if dataLine.hasPrefix(" ") {
                    dataLine.removeFirst()
                }
                dataLines.append(dataLine)
            }
        }
        try emitEvent()
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_000_000 else { break }
            data.append(byte)
        }
        return data
    }

    private func streamingError(in data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ChatErrorEnvelope.self, from: data),
              let message = envelope.error?.message ?? envelope.message,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    private func openAIStreamDelta(in data: Data) -> OpenAIStreamDelta? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let model = payload["model"] as? String
        let usage = payload["usage"].flatMap { usageValue -> OpenAIChatCompletionResponse.Usage? in
            guard JSONSerialization.isValidJSONObject(usageValue),
                  let usageData = try? JSONSerialization.data(withJSONObject: usageValue) else {
                return nil
            }
            return try? JSONDecoder().decode(OpenAIChatCompletionResponse.Usage.self, from: usageData)
        }
        return OpenAIStreamDelta(
            model: model,
            usage: usage,
            text: textDelta(in: payload)
        )
    }

    private func textDelta(in payload: [String: Any]) -> String {
        let choiceText = (payload["choices"] as? [[String: Any]])?
            .compactMap { choice in
                textValue(choice["delta"])
                    ?? textValue(choice["message"])
                    ?? textValue(choice["text"])
            }
            .joined() ?? ""
        if !choiceText.isEmpty { return choiceText }

        if let nestedPayload = payload["data"] as? [String: Any] {
            let nestedText = textDelta(in: nestedPayload)
            if !nestedText.isEmpty { return nestedText }
        }
        return textValue(payload["delta"])
            ?? textValue(payload["text"])
            ?? textValue(payload["content"])
            ?? ""
    }

    private func textValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let values = value as? [Any] {
            let text = values.compactMap(textValue).joined()
            return text.isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            return textValue(object["content"])
                ?? textValue(object["text"])
                ?? textValue(object["delta"])
        }
        return nil
    }

    private func sum(_ values: Int?...) -> Int? {
        let availableValues = values.compactMap { $0 }
        guard !availableValues.isEmpty else { return nil }
        return availableValues.reduce(0, +)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatAPIError.httpStatus(
                httpResponse.statusCode,
                parseErrorMessage(from: data, statusCode: httpResponse.statusCode)
            )
        }
        return data
    }

    private func validatedContent(_ value: String) throws -> String {
        let content = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ChatAPIError.missingContent
        }
        return content
    }

    private func endpointURL(from rawValue: String, appending endpointPath: String) throws -> URL {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: normalized),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            throw ChatAPIError.invalidBaseURL(rawValue)
        }

        if baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .hasSuffix(endpointPath) {
            return baseURL
        }
        return baseURL.appending(path: endpointPath)
    }

    private func parseErrorMessage(from data: Data, statusCode: Int) -> String {
        if let envelope = try? JSONDecoder().decode(ChatErrorEnvelope.self, from: data),
           let message = envelope.error?.message ?? envelope.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plainText.isEmpty,
           !plainText.hasPrefix("<") {
            return String(plainText.prefix(500))
        }
        return "聊天请求失败，状态码 \(statusCode)。"
    }
}

private struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatRequestMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct OpenAIChatCompletionResponse: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: ChatResponseContent
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct OpenAIStreamDelta {
    let model: String?
    let usage: OpenAIChatCompletionResponse.Usage?
    let text: String
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let system: String?
    let messages: [ChatRequestMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct AnthropicMessagesResponse: Decodable {
    let model: String?
    let content: ChatResponseContent
    let usage: Usage?

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }

        var promptTokens: Int? {
            sum(inputTokens, cacheCreationInputTokens, cacheReadInputTokens)
        }

        var totalTokens: Int? {
            sum(promptTokens, outputTokens)
        }

        private func sum(_ values: Int?...) -> Int? {
            let availableValues = values.compactMap { $0 }
            guard !availableValues.isEmpty else { return nil }
            return availableValues.reduce(0, +)
        }
    }
}

private struct AnthropicStreamEvent: Decodable {
    let type: String
    let message: Message?
    let delta: Delta?
    let usage: Usage?

    struct Message: Decodable {
        let model: String?
        let usage: Usage?
    }

    struct Delta: Decodable {
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }

        var promptTokens: Int? {
            let values = [inputTokens, cacheCreationInputTokens, cacheReadInputTokens]
                .compactMap { $0 }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +)
        }
    }
}

private enum ChatResponseContent: Decodable {
    case text(String)
    case parts([ContentPart])
    case empty

    struct ContentPart: Decodable {
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .empty
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let values = try? container.decode([ContentPart].self) {
            self = .parts(values)
        } else if let value = try? container.decode(ContentPart.self) {
            self = .parts([value])
        } else {
            self = .empty
        }
    }

    var text: String {
        switch self {
        case .text(let value):
            value
        case .parts(let values):
            values.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .empty:
            ""
        }
    }
}

private struct ChatErrorEnvelope: Decodable {
    let error: ErrorBody?
    let message: String?

    struct ErrorBody: Decodable {
        let message: String?
    }
}

enum ChatAPIError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case invalidPayload(String)
    case missingChoices
    case missingContent
    case network(String)
    case httpStatus(Int, String)
    case streaming(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "Base URL 无效：\(value)"
        case .invalidResponse:
            "模型服务返回了无效响应。"
        case .invalidPayload(let detail):
            "无法解析模型响应：\(detail)"
        case .missingChoices:
            "模型响应中没有 choices。"
        case .missingContent:
            "模型响应中没有可显示的文本。"
        case .network(let detail):
            "无法连接模型服务：\(detail)"
        case .httpStatus(_, let message):
            message
        case .streaming(let message):
            "模型流式输出失败：\(message)"
        }
    }
}
