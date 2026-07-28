import Foundation

enum AppSection: Hashable, CaseIterable {
    case chat
    case agent
    case media
    case skills
    case models

    var displayName: String {
        switch self {
        case .chat: "聊天"
        case .agent: "Agent"
        case .media: "媒体"
        case .skills: "技能"
        case .models: "模型"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .agent: "terminal"
        case .media: "photo.on.rectangle.angled"
        case .skills: "wand.and.stars"
        case .models: "cpu"
        }
    }
}

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
}

enum AIModelCategory: String, Codable, CaseIterable, Sendable {
    case chat
    case agent
    case image
    case video

    var displayName: String {
        switch self {
        case .chat: "聊天"
        case .agent: "Agent"
        case .image: "图片"
        case .video: "视频"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "message"
        case .agent: "terminal"
        case .image: "photo"
        case .video: "video"
        }
    }
}

enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompatible
    case anthropicCompatible

    var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropicCompatible: "Anthropic 兼容"
        }
    }
}

enum AgentEngineKind: String, Codable, CaseIterable, Sendable {
    case disabled
    case codexCLI
    case claudeCodeCLI
    case grokBuildCLI

    var displayName: String {
        switch self {
        case .disabled: "不启用 Agent"
        case .codexCLI: "Codex CLI"
        case .claudeCodeCLI: "Claude Code CLI"
        case .grokBuildCLI: "Grok Build CLI"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "minus.circle"
        case .codexCLI: "terminal"
        case .claudeCodeCLI: "chevron.left.forwardslash.chevron.right"
        case .grokBuildCLI: "bolt.horizontal.fill"
        }
    }

    var supportedAPIs: [AgentAPIKind] {
        switch self {
        case .disabled: []
        case .codexCLI: [.responses]
        case .claudeCodeCLI: [.anthropicMessages]
        case .grokBuildCLI: [.responses, .chatCompletions]
        }
    }

    static var configurationChannels: [AgentEngineKind] {
        [.codexCLI, .claudeCodeCLI]
    }

    nonisolated var channelDisplayName: String {
        switch self {
        case .disabled: "未配置"
        case .codexCLI: "Codex"
        case .claudeCodeCLI: "Claude"
        case .grokBuildCLI: "Grok"
        }
    }

    var defaultProvider: AIProviderKind {
        self == .claudeCodeCLI ? .anthropicCompatible : .openAICompatible
    }

    var supportedReasoningEfforts: [AgentReasoningEffort] {
        switch self {
        case .disabled:
            [.automatic]
        case .codexCLI:
            [.automatic, .minimal, .low, .medium, .high, .xhigh]
        case .claudeCodeCLI:
            [.automatic, .low, .medium, .high, .xhigh, .max]
        case .grokBuildCLI:
            AgentReasoningEffort.allCases
        }
    }
}

enum AgentReasoningEffort: String, Codable, CaseIterable, Sendable {
    case automatic
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .none: "关闭"
        case .minimal: "极低"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        case .max: "最大"
        }
    }

    var commandValue: String? {
        self == .automatic ? nil : rawValue
    }
}

enum AgentAPIKind: String, Codable, CaseIterable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages

    var displayName: String {
        switch self {
        case .responses: "Responses API"
        case .chatCompletions: "Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

enum MediaAPIKind: String, Codable, CaseIterable, Sendable {
    case imageGenerations
    case chatCompletions
    case videoGenerations

    var displayName: String {
        switch self {
        case .imageGenerations: "Images API"
        case .chatCompletions: "Chat Completions 图像"
        case .videoGenerations: "Videos API"
        }
    }

    static func supportedCases(for category: AIModelCategory) -> [MediaAPIKind] {
        switch category {
        case .chat, .agent: []
        case .image: [.imageGenerations, .chatCompletions]
        case .video: [.videoGenerations]
        }
    }

    static func defaultValue(for category: AIModelCategory) -> MediaAPIKind {
        switch category {
        case .chat, .agent, .image: .imageGenerations
        case .video: .videoGenerations
        }
    }
}

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
}

enum MediaOperation: String, Codable, CaseIterable, Sendable {
    case generate
    case edit
    case compatible
    case videoGenerate
}
