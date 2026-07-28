import Foundation

struct NormalizedSkillContent: Sendable {
    let name: String
    let skillDescription: String
    let systemPrompt: String
}

enum SkillConfigurationStore {
    static func normalizedContent(
        name: String,
        skillDescription: String,
        systemPrompt: String
    ) throws -> NormalizedSkillContent {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = skillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty else {
            throw SkillConfigurationError.emptyName
        }
        guard normalizedName.count <= 128 else {
            throw SkillConfigurationError.nameTooLong
        }
        guard normalizedName.range(
            of: #"^[\p{L}\p{N} _-]+$"#,
            options: .regularExpression
        ) != nil else {
            throw SkillConfigurationError.invalidNameCharacters
        }
        guard normalizedDescription.count <= 255 else {
            throw SkillConfigurationError.descriptionTooLong
        }
        guard !normalizedPrompt.isEmpty else {
            throw SkillConfigurationError.emptySystemPrompt
        }

        return NormalizedSkillContent(
            name: normalizedName,
            skillDescription: normalizedDescription,
            systemPrompt: normalizedPrompt
        )
    }

    static func hasDuplicateName(
        _ name: String,
        editingID: UUID?,
        in skills: [Skill]
    ) -> Bool {
        skills.contains {
            $0.id != editingID
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func clearConversationSelections(for skill: Skill) {
        for conversation in Array(skill.conversations) {
            conversation.selectedSkill = nil
            conversation.touch()
        }
    }
}

enum SkillConfigurationError: LocalizedError {
    case emptyName
    case nameTooLong
    case invalidNameCharacters
    case descriptionTooLong
    case emptySystemPrompt

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Skill 名称不能为空。"
        case .nameTooLong:
            "Skill 名称不能超过 128 个字符。"
        case .invalidNameCharacters:
            "Skill 名称只能包含文字、数字、空格、下划线和横线。"
        case .descriptionTooLong:
            "Skill 简介不能超过 255 个字符。"
        case .emptySystemPrompt:
            "System Prompt 不能为空。"
        }
    }
}
