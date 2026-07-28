import Foundation
import SwiftData

@Model
final class Skill {
    @Attribute(.unique) var id: UUID
    var name: String
    var skillDescription: String
    var systemPrompt: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var conversations: [Conversation]

    init(
        id: UUID = UUID(),
        name: String,
        skillDescription: String = "",
        systemPrompt: String,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.skillDescription = skillDescription
        self.systemPrompt = systemPrompt
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversations = []
    }
}
