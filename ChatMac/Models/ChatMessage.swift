import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRawValue: String
    var content: String
    var sequence: Int
    var createdAt: Date
    var modelName: String?
    var errorText: String?
    var responseDurationMilliseconds: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var conversation: Conversation?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        sequence: Int,
        createdAt: Date = .now,
        modelName: String? = nil,
        errorText: String? = nil,
        responseDurationMilliseconds: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        conversation: Conversation? = nil
    ) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.content = content
        self.sequence = sequence
        self.createdAt = createdAt
        self.modelName = modelName
        self.errorText = errorText
        self.responseDurationMilliseconds = responseDurationMilliseconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.conversation = conversation
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }
}
