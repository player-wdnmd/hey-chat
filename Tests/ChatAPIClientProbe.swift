import Foundation

@main
struct ChatAPIClientProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let port = Int(CommandLine.arguments[1]) else {
            throw ProbeError.invalidArguments
        }

        let client = ChatAPIClient()
        let baseURL = "http://127.0.0.1:\(port)/v1"
        let messages = [
            ChatRequestMessage(role: .system, content: "system prompt"),
            ChatRequestMessage(role: .system, content: "skill prompt"),
            ChatRequestMessage(role: .user, content: "hello mock"),
        ]

        try verifyContextBuilder()

        let success = try await client.complete(
            messages: messages,
            target: target(model: "mock-success", baseURL: baseURL),
            apiKey: nil,
            maxTokens: 64
        )

        guard success.content == "mock\n\nresponse",
              success.model == "mock-model",
              success.promptTokens == 12,
              success.completionTokens == 5,
              success.totalTokens == 17 else {
            throw ProbeError.unexpectedSuccessPayload
        }

        let anthropicSuccess = try await client.complete(
            messages: messages,
            target: target(
                model: "anthropic-success",
                baseURL: baseURL,
                provider: .anthropicCompatible
            ),
            apiKey: "test-anthropic-key",
            maxTokens: 64
        )

        guard anthropicSuccess.content == "anthropic\n\nresponse",
              anthropicSuccess.model == "anthropic-model",
              anthropicSuccess.promptTokens == 25,
              anthropicSuccess.completionTokens == 4,
              anthropicSuccess.totalTokens == 29 else {
            throw ProbeError.unexpectedAnthropicPayload
        }

        do {
            _ = try await client.complete(
                messages: messages,
                target: target(model: "mock-error", baseURL: baseURL),
                apiKey: nil,
                maxTokens: 64
            )
            throw ProbeError.expectedHTTPError
        } catch let error as ChatAPIError {
            guard case .httpStatus(429, let message) = error,
                  message == "mock rate limit" else {
                throw ProbeError.unexpectedHTTPError
            }
        }

        let slowTask = Task {
            try await client.complete(
                messages: messages,
                target: target(model: "mock-slow", baseURL: baseURL),
                apiKey: nil,
                maxTokens: 64
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        slowTask.cancel()

        do {
            _ = try await slowTask.value
            throw ProbeError.expectedCancellation
        } catch is CancellationError {
            // Expected.
        }

        print("ChatAPIClient mock probe passed")
    }

    private static func verifyContextBuilder() throws {
        var history = (0..<82).map {
            ChatContextMessageSnapshot(role: .user, content: "valid-\($0)", isFailed: false)
        }
        history.append(ChatContextMessageSnapshot(role: .system, content: "stored system", isFailed: false))
        history.append(ChatContextMessageSnapshot(role: .assistant, content: "failed", isFailed: true))
        history.append(ChatContextMessageSnapshot(role: .assistant, content: "   ", isFailed: false))

        let messages = ChatContextBuilder.makeMessages(
            history: history,
            skill: ChatSkillPromptSnapshot(name: "Test Skill", systemPrompt: "Skill Prompt")
        )

        guard messages.count == 82,
              messages[0].role == MessageRole.system.rawValue,
              messages[0].content == ChatContextBuilder.globalSystemPrompt,
              messages[1].content == "当前启用技能《Test Skill》：\nSkill Prompt",
              messages[2].content == "valid-2",
              messages.last?.content == "valid-81",
              !messages.contains(where: { $0.content == "failed" || $0.content == "stored system" }) else {
            throw ProbeError.unexpectedContext
        }
    }

    private static func target(
        model: String,
        baseURL: String,
        provider: AIProviderKind = .openAICompatible
    ) -> ChatModelTarget {
        ChatModelTarget(
            modelIdentifier: model,
            displayName: "Mock",
            provider: provider,
            baseURLString: baseURL,
            keychainAccount: "unused"
        )
    }
}

private enum ProbeError: LocalizedError {
    case invalidArguments
    case unexpectedSuccessPayload
    case unexpectedAnthropicPayload
    case expectedHTTPError
    case unexpectedHTTPError
    case expectedCancellation
    case unexpectedContext

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Expected a mock server port."
        case .unexpectedSuccessPayload: "Success payload did not decode as expected."
        case .unexpectedAnthropicPayload: "Anthropic payload did not decode as expected."
        case .expectedHTTPError: "Expected an HTTP error response."
        case .unexpectedHTTPError: "HTTP error did not preserve its status and message."
        case .expectedCancellation: "Expected the slow request to be cancelled."
        case .unexpectedContext: "Chat context ordering or filtering was incorrect."
        }
    }
}
