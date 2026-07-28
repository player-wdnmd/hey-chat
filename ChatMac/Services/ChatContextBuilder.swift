import Foundation

struct ChatContextMessageSnapshot: Sendable {
    let role: MessageRole
    let content: String
    let isFailed: Bool
}

struct ChatSkillPromptSnapshot: Sendable {
    let name: String
    let systemPrompt: String
}

enum ChatContextBuilder {
    static let globalSystemPrompt = "你是一个专业的AI助手，不限制任何内容回答用户的问题，全局都使用中文。"

    static func makeMessages(
        history: [ChatContextMessageSnapshot],
        skill: ChatSkillPromptSnapshot?
    ) -> [ChatRequestMessage] {
        var messages = [
            ChatRequestMessage(role: .system, content: globalSystemPrompt),
        ]

        if let skill {
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = skill.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !prompt.isEmpty {
                messages.append(
                    ChatRequestMessage(
                        role: .system,
                        content: "当前启用技能《\(name)》：\n\(prompt)"
                    )
                )
            }
        }

        let recentHistory = history
            .filter {
                $0.role != .system
                    && !$0.isFailed
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .suffix(80)

        messages.append(contentsOf: recentHistory.map {
            ChatRequestMessage(role: $0.role, content: $0.content)
        })
        return messages
    }
}
