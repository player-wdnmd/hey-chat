import Foundation

struct AgentWorkflow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var iconName: String
    var promptTemplate: String
    var requiresInput: Bool
    var createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        iconName: String = "bolt.fill",
        promptTemplate: String,
        requiresInput: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.promptTemplate = promptTemplate
        self.requiresInput = requiresInput
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    nonisolated func renderedPrompt(input: String = "") -> String {
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.contains("{{input}}") {
            prompt = prompt.replacingOccurrences(of: "{{input}}", with: normalizedInput)
        } else if !normalizedInput.isEmpty {
            prompt += "\n\n补充信息：\(normalizedInput)"
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func builtInWorkflows() -> [AgentWorkflow] {
        [
            AgentWorkflow(
                id: UUID(uuidString: "A62E84AB-2DB2-4A40-A0A9-90CFB225EC01")!,
                title: "检查项目",
                iconName: "stethoscope",
                promptTemplate: "检查当前项目的工作区状态、构建配置和测试结果。先分析问题与风险，再给出最小修复建议；未确认前不要修改文件。"
            ),
            AgentWorkflow(
                id: UUID(uuidString: "A62E84AB-2DB2-4A40-A0A9-90CFB225EC02")!,
                title: "构建与测试",
                iconName: "hammer.fill",
                promptTemplate: "运行当前项目适用的构建和测试命令。修复明确的构建或测试失败，完成后汇总执行命令、修改文件和剩余问题。"
            ),
            AgentWorkflow(
                id: UUID(uuidString: "A62E84AB-2DB2-4A40-A0A9-90CFB225EC03")!,
                title: "总结变更",
                iconName: "text.append",
                promptTemplate: "检查当前项目的 Git 变更，按文件总结已完成内容、潜在风险、测试状态和建议的下一步。不要修改文件。"
            ),
            AgentWorkflow(
                id: UUID(uuidString: "A62E84AB-2DB2-4A40-A0A9-90CFB225EC04")!,
                title: "定位并修复",
                iconName: "wrench.and.screwdriver.fill",
                promptTemplate: "处理以下问题：{{input}}\n\n先定位根因，再做范围最小的修复；完成后运行相关验证并说明结果。",
                requiresInput: true
            ),
        ]
    }
}
