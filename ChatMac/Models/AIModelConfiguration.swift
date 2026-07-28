import Foundation
import SwiftData

@Model
final class AIModelConfiguration {
    @Attribute(.unique) var id: UUID
    var modelIdentifier: String
    var displayName: String
    var modelDescription: String
    var categoryRawValue: String
    var providerRawValue: String
    var mediaAPIKindRawValue: String?
    var channelName: String?
    var baseURLString: String
    var keychainAccount: String
    var agentEngineRawValue: String?
    var agentAPIKindRawValue: String?
    var agentCredentialRawValue: String?
    var agentModelIdentifier: String?
    var agentBaseURLString: String?
    var agentReasoningEffortRawValue: String?
    var sortOrder: Int
    var isEnabled: Bool
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date
    var conversations: [Conversation]

    init(
        id: UUID = UUID(),
        modelIdentifier: String,
        displayName: String,
        modelDescription: String = "",
        category: AIModelCategory = .chat,
        provider: AIProviderKind = .openAICompatible,
        mediaAPIKind: MediaAPIKind? = nil,
        channelName: String? = nil,
        baseURLString: String,
        keychainAccount: String? = nil,
        agentEngine: AgentEngineKind? = nil,
        agentAPIKind: AgentAPIKind? = nil,
        agentModelIdentifier: String? = nil,
        agentBaseURLString: String? = nil,
        agentReasoningEffort: AgentReasoningEffort = .automatic,
        sortOrder: Int = 0,
        isEnabled: Bool = true,
        isDefault: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName
        self.modelDescription = modelDescription
        self.categoryRawValue = category.rawValue
        self.providerRawValue = provider.rawValue
        self.mediaAPIKindRawValue = mediaAPIKind?.rawValue
        self.channelName = channelName
        self.baseURLString = baseURLString
        self.keychainAccount = keychainAccount ?? "chatmac.model.\(id.uuidString)"
        self.agentEngineRawValue = agentEngine?.rawValue
        self.agentAPIKindRawValue = agentAPIKind?.rawValue
        self.agentCredentialRawValue = "apiKey"
        self.agentModelIdentifier = agentModelIdentifier
        self.agentBaseURLString = agentBaseURLString
        self.agentReasoningEffortRawValue = agentReasoningEffort.rawValue
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversations = []
    }

    var category: AIModelCategory {
        get { AIModelCategory(rawValue: categoryRawValue) ?? .chat }
        set { categoryRawValue = newValue.rawValue }
    }

    var hasSupportedCategory: Bool {
        AIModelCategory(rawValue: categoryRawValue) != nil
    }

    var provider: AIProviderKind {
        get { AIProviderKind(rawValue: providerRawValue) ?? .openAICompatible }
        set { providerRawValue = newValue.rawValue }
    }

    var mediaAPIKind: MediaAPIKind {
        get {
            MediaAPIKind(rawValue: mediaAPIKindRawValue ?? "")
                ?? MediaAPIKind.defaultValue(for: category)
        }
        set { mediaAPIKindRawValue = newValue.rawValue }
    }

    var resolvedChannelName: String {
        let trimmed = channelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? provider.displayName : trimmed
    }

    var agentEngine: AgentEngineKind {
        get {
            if let rawValue = agentEngineRawValue,
               let value = AgentEngineKind(rawValue: rawValue),
               category != .agent || AgentEngineKind.configurationChannels.contains(value) {
                return value
            }
            guard category == .agent else { return .disabled }
            return provider == .anthropicCompatible ? .claudeCodeCLI : .codexCLI
        }
        set { agentEngineRawValue = newValue.rawValue }
    }

    var agentAPIKind: AgentAPIKind {
        get {
            if let rawValue = agentAPIKindRawValue,
               let value = AgentAPIKind(rawValue: rawValue),
               agentEngine.supportedAPIs.contains(value) {
                return value
            }
            return agentEngine.supportedAPIs.first ?? .responses
        }
        set { agentAPIKindRawValue = newValue.rawValue }
    }

    var resolvedAgentModelIdentifier: String {
        let trimmed = agentModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? modelIdentifier : trimmed
    }

    var resolvedAgentBaseURLString: String {
        let trimmed = agentBaseURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? baseURLString : trimmed
    }

    var agentReasoningEffort: AgentReasoningEffort {
        get {
            AgentReasoningEffort(rawValue: agentReasoningEffortRawValue ?? "") ?? .automatic
        }
        set { agentReasoningEffortRawValue = newValue.rawValue }
    }

    var supportsAgent: Bool {
        category == .agent
            && isEnabled
            && AgentEngineKind.configurationChannels.contains(agentEngine)
            && agentEngine.supportedAPIs.contains(agentAPIKind)
    }
}
