import SwiftData

@main
struct SkillDataProbe {
    @MainActor
    static func main() throws {
        let normalized = try SkillConfigurationStore.normalizedContent(
            name: "  Test_Skill-1  ",
            skillDescription: "  local description  ",
            systemPrompt: "  local prompt  "
        )
        guard normalized.name == "Test_Skill-1",
              normalized.skillDescription == "local description",
              normalized.systemPrompt == "local prompt" else {
            throw ProbeError.normalizationFailed
        }

        do {
            _ = try SkillConfigurationStore.normalizedContent(
                name: "bad/name",
                skillDescription: "",
                systemPrompt: "prompt"
            )
            throw ProbeError.invalidNameAccepted
        } catch is SkillConfigurationError {
            // Expected.
        }

        let schema = Schema([
            Conversation.self,
            ChatMessage.self,
            AIModelConfiguration.self,
            Skill.self,
        ])
        let configuration = SwiftData.ModelConfiguration(
            "SkillProbe",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let skill = Skill(name: "Probe Skill", systemPrompt: "Probe Prompt")
        let conversation = Conversation(title: "Probe Conversation", selectedSkill: skill)
        let message = ChatMessage(
            role: .user,
            content: "Keep me",
            sequence: 0,
            conversation: conversation
        )
        context.insert(skill)
        context.insert(conversation)
        context.insert(message)
        try context.save()

        guard conversation.selectedSkill?.id == skill.id,
              skill.conversations.contains(where: { $0.id == conversation.id }) else {
            throw ProbeError.inverseRelationshipMissing
        }

        SkillConfigurationStore.clearConversationSelections(for: skill)
        skill.isEnabled = false
        try context.save()

        guard conversation.selectedSkill == nil,
              conversation.messages.count == 1 else {
            throw ProbeError.disableCleanupFailed
        }

        context.delete(skill)
        try context.save()

        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        let skills = try context.fetch(FetchDescriptor<Skill>())
        guard conversations.count == 1, messages.count == 1, skills.isEmpty else {
            throw ProbeError.deleteCascadeFailed
        }

        print("Skill data probe passed")
    }
}

private enum ProbeError: Error {
    case normalizationFailed
    case invalidNameAccepted
    case inverseRelationshipMissing
    case disableCleanupFailed
    case deleteCascadeFailed
}
