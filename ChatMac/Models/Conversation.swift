import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .nullify, inverse: \AIModelConfiguration.conversations)
    var selectedModel: AIModelConfiguration?

    @Relationship(deleteRule: .nullify, inverse: \Skill.conversations)
    var selectedSkill: Skill?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        selectedModel: AIModelConfiguration? = nil,
        selectedSkill: Skill? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModel = selectedModel
        self.selectedSkill = selectedSkill
        self.messages = []
    }

    var orderedMessages: [ChatMessage] {
        messages.sorted {
            if $0.sequence == $1.sequence {
                return $0.createdAt < $1.createdAt
            }
            return $0.sequence < $1.sequence
        }
    }

    var latestPreview: String {
        guard let content = orderedMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return "暂无消息"
        }

        return content.replacingOccurrences(of: "\n", with: " ")
    }

    func touch(at date: Date = .now) {
        updatedAt = date
    }
}
