import Foundation

struct AgentProjectMemory: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var projectGoal: String
    var technicalContext: String
    var commonCommands: String
    var conventions: String
    var constraints: String
    var knownIssues: String
    var updatedAt: Date

    nonisolated init(
        isEnabled: Bool = true,
        projectGoal: String = "",
        technicalContext: String = "",
        commonCommands: String = "",
        conventions: String = "",
        constraints: String = "",
        knownIssues: String = "",
        updatedAt: Date = .now
    ) {
        self.isEnabled = isEnabled
        self.projectGoal = projectGoal
        self.technicalContext = technicalContext
        self.commonCommands = commonCommands
        self.conventions = conventions
        self.constraints = constraints
        self.knownIssues = knownIssues
        self.updatedAt = updatedAt
    }

    nonisolated var context: String? {
        guard isEnabled else { return nil }
        let sections = [
            section(title: "项目目标", content: projectGoal),
            section(title: "技术栈与架构", content: technicalContext),
            section(title: "常用命令", content: commonCommands),
            section(title: "代码规范", content: conventions),
            section(title: "约束与注意事项", content: constraints),
            section(title: "已知问题与后续事项", content: knownIssues),
        ].compactMap { $0 }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated func section(title: String, content: String) -> String? {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "## \(title)\n\(normalized)"
    }
}

struct AgentPersonalPreferences: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var content: String
    var updatedAt: Date

    nonisolated init(
        isEnabled: Bool = true,
        content: String = "",
        updatedAt: Date = .now
    ) {
        self.isEnabled = isEnabled
        self.content = content
        self.updatedAt = updatedAt
    }

    nonisolated var context: String? {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return isEnabled && !normalized.isEmpty ? normalized : nil
    }
}
