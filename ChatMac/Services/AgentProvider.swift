import Foundation

struct AgentProviderTarget: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelName: String
    let engine: AgentEngineKind
    let apiKind: AgentAPIKind
    let modelIdentifier: String?
    let baseURLString: String?
    let keychainAccount: String?
    let defaultReasoningEffort: AgentReasoningEffort

    var subtitle: String {
        "\(channelName) · \(apiKind.displayName) · 推理 \(defaultReasoningEffort.displayName)"
    }

    nonisolated static func configuredModel(_ model: AIModelConfiguration) -> AgentProviderTarget? {
        guard model.supportsAgent else { return nil }
        return AgentProviderTarget(
            id: "model-\(model.id.uuidString)",
            title: model.displayName,
            channelName: model.agentEngine.channelDisplayName,
            engine: model.agentEngine,
            apiKind: model.agentAPIKind,
            modelIdentifier: model.resolvedAgentModelIdentifier,
            baseURLString: model.resolvedAgentBaseURLString,
            keychainAccount: model.keychainAccount,
            defaultReasoningEffort: model.agentReasoningEffort
        )
    }
}

protocol AgentRunningProvider: AnyObject {
    func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel()
}

final class AgentProviderRouter: AgentRunningProvider {
    private let codex = CodexCLIAgentProvider()
    private let claude = ClaudeCodeCLIAgentProvider()
    private let grok = GrokBuildCLIAgentProvider()
    private let lock = NSLock()
    private weak var activeProvider: AgentRunningProvider?

    func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let provider: AgentRunningProvider
        switch request.target.engine {
        case .codexCLI:
            provider = codex
        case .claudeCodeCLI:
            provider = claude
        case .grokBuildCLI:
            provider = grok
        case .disabled:
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AgentProviderError.incompatibleConfiguration)
            }
        }
        lock.lock()
        activeProvider = provider
        lock.unlock()
        return provider.run(request)
    }

    func cancel() {
        lock.lock()
        let provider = activeProvider
        activeProvider = nil
        lock.unlock()
        provider?.cancel()
    }
}

enum AgentEvent: Sendable {
    case threadStarted(String)
    case status(String)
    case assistant(String)
    case command(command: String, output: String, exitCode: Int?)
    case fileChange(String)
    case planProgress(currentStep: Int, totalSteps: Int)
    case warning(String)
    case completed(AgentUsage?)

    nonisolated var indicatesSubstantiveProgress: Bool {
        switch self {
        case .assistant, .command, .fileChange, .planProgress, .completed:
            true
        case .threadStarted, .status, .warning:
            false
        }
    }
}

struct AgentUsage: Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
}

struct AgentRunRequest: Sendable {
    let prompt: String
    let attachments: [AgentAttachmentRecord]
    let workspaceURL: URL
    let additionalWritableURLs: [URL]
    let target: AgentProviderTarget
    let threadID: String?
    let contextHandoff: String?
    let reasoningEffort: AgentReasoningEffort

    var effectivePrompt: String {
        var promptParts: [String] = []
        if let contextHandoff, !contextHandoff.isEmpty {
            promptParts.append("""
            <chatmac_context_handoff>
            \(contextHandoff)
            </chatmac_context_handoff>
            """)
        }
        promptParts.append(prompt)
        let promptWithHandoff = promptParts.joined(separator: "\n\n")
        guard !attachments.isEmpty else { return promptWithHandoff }
        let attachmentList = attachments.map { attachment in
            let safePath = attachment.path.replacingOccurrences(of: "\n", with: "\\n")
            return "- \(safePath)"
        }.joined(separator: "\n")
        let instruction = """
        用户通过客户端附加了以下本机文件。请根据任务需要使用工具读取这些文件：
        \(attachmentList)
        """
        if promptWithHandoff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请查看并处理附件。\n\n\(instruction)"
        }
        return "\(promptWithHandoff)\n\n\(instruction)"
    }

    var imageAttachments: [AgentAttachmentRecord] {
        attachments.filter(\.isImage)
    }
}

enum AgentProviderError: LocalizedError {
    case codexUnavailable
    case claudeUnavailable
    case grokUnavailable
    case invalidWorkspace
    case missingAPIKey(String)
    case invalidBaseURL(String)
    case incompatibleConfiguration
    case processFailed(String)
    case malformedEvent

    var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            "没有找到 Codex CLI。请先在终端安装 Codex。"
        case .claudeUnavailable:
            "没有找到 Claude Code CLI。请先安装 Claude Code。"
        case .grokUnavailable:
            "没有找到 Grok Build CLI。请先安装 @xai-official/grok。"
        case .invalidWorkspace:
            "请选择一个仍然存在的项目目录。"
        case .missingAPIKey(let modelName):
            "模型“\(modelName)”没有可用的 API Key。请先在模型管理中保存密钥。"
        case .invalidBaseURL(let value):
            "Agent Base URL 无效：\(value)"
        case .incompatibleConfiguration:
            "当前 Agent 引擎与接口协议不兼容，请在模型管理中检查配置。"
        case .processFailed(let message):
            message.isEmpty ? "Agent 运行失败。" : message
        case .malformedEvent:
            "Agent 返回了无法解析的事件。"
        }
    }
}
