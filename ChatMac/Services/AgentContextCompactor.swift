import Foundation

struct AgentContextCompactionPlan {
    let summary: String
    let estimatedTokens: Int
    let sourceEntryCount: Int
    let reason: String
}

struct AgentContextCompactor {
    private struct Policy {
        let inputTokenHighWatermark: Int
        let estimatedTokenHighWatermark: Int
    }

    static func compactionPlan(
        for session: AgentSessionRecord,
        projectPath: String,
        engine: AgentEngineKind,
        pendingPrompt: String
    ) -> AgentContextCompactionPlan? {
        guard session.threadID != nil else { return nil }

        let startIndex = min(max(0, session.compactedEntryCount ?? 0), session.entries.count)
        let newEntries = Array(session.entries.dropFirst(startIndex))
        let userTurnCount = newEntries.filter { $0.kind == .user }.count
        guard userTurnCount >= 2 else { return nil }

        let policy = policy(for: engine)
        let lastInputTokens = session.lastInputTokens
            ?? session.entries.reversed().compactMap(\.inputTokens).first
        let estimatedTokens = estimateTokens(
            entries: newEntries,
            existingSummary: session.contextSummary,
            pendingPrompt: pendingPrompt
        )

        let reason: String?
        if let lastInputTokens, lastInputTokens >= policy.inputTokenHighWatermark {
            reason = "输入上下文达到 \(lastInputTokens.formatted()) tokens"
        } else if estimatedTokens >= policy.estimatedTokenHighWatermark {
            reason = "估算上下文达到 \(estimatedTokens.formatted()) tokens"
        } else if userTurnCount >= 28 && estimatedTokens >= 48_000 {
            reason = "连续 \(userTurnCount) 轮对话且上下文较长"
        } else if newEntries.count >= 140 && estimatedTokens >= 40_000 {
            reason = "工具事件累计 \(newEntries.count) 条"
        } else {
            return nil
        }
        guard let reason else { return nil }

        return AgentContextCompactionPlan(
            summary: makeHandoffSummary(entries: session.entries, projectPath: projectPath),
            estimatedTokens: estimatedTokens,
            sourceEntryCount: session.entries.count,
            reason: reason
        )
    }

    static func recoveryPlan(
        entries: [AgentTranscriptEntry],
        projectPath: String,
        reason: String
    ) -> AgentContextCompactionPlan {
        AgentContextCompactionPlan(
            summary: makeHandoffSummary(entries: entries, projectPath: projectPath),
            estimatedTokens: estimateTokens(entries: entries, existingSummary: nil, pendingPrompt: ""),
            sourceEntryCount: entries.count,
            reason: reason
        )
    }

    private static func policy(for engine: AgentEngineKind) -> Policy {
        switch engine {
        case .claudeCodeCLI:
            Policy(inputTokenHighWatermark: 150_000, estimatedTokenHighWatermark: 130_000)
        case .codexCLI, .grokBuildCLI, .disabled:
            Policy(inputTokenHighWatermark: 120_000, estimatedTokenHighWatermark: 100_000)
        }
    }

    private static func estimateTokens(
        entries: [AgentTranscriptEntry],
        existingSummary: String?,
        pendingPrompt: String
    ) -> Int {
        var characters = existingSummary?.count ?? 0
        characters += pendingPrompt.count
        for entry in entries where entry.kind != .contextCompact
            && entry.kind != .modelSwitch
            && entry.kind != .completion {
            characters += entry.content.count
            if entry.kind == .command {
                characters += min(entry.detail?.count ?? 0, 16_000)
            } else {
                characters += min(entry.detail?.count ?? 0, 4_000)
            }
            characters += entry.attachments?.reduce(0) { $0 + $1.path.count } ?? 0
        }
        return max(1, Int(ceil(Double(characters) / 3.2)))
    }

    private static func makeHandoffSummary(
        entries: [AgentTranscriptEntry],
        projectPath: String
    ) -> String {
        let relevantEntries = entries.filter {
            $0.kind != .contextCompact && $0.kind != .modelSwitch && $0.kind != .completion
        }
        let userEntries = relevantEntries.filter { $0.kind == .user }
        let dialogueEntries = relevantEntries.filter { $0.kind == .user || $0.kind == .assistant }
        let fileChanges = relevantEntries.filter { $0.kind == .fileChange }
        let commands = relevantEntries.filter { $0.kind == .command }
        let issues = relevantEntries.filter { $0.kind == .warning || $0.kind == .error }

        var sections = [
            "这是 hey chat 在切换 CLI 会话时生成的结构化上下文交接。请把它作为既有事实背景，继续处理本轮用户请求；不要重复已经完成的工作，也不要假定未验证的结果。",
            "## 项目\n- 工作目录：\(projectPath)\n- 完整可见历史保留在 hey chat，本交接只提供继续执行所需的高信号上下文。",
        ]

        let initialRequirements = Array(userEntries.prefix(5))
        if !initialRequirements.isEmpty {
            sections.append(section(
                title: "长期目标与约束",
                lines: initialRequirements.map { "- \(singleLine($0.content, limit: 1_200))" },
                limit: 6_500
            ))
        }

        let recentDialogue = Array(dialogueEntries.suffix(10))
        if !recentDialogue.isEmpty {
            sections.append(section(
                title: "最近对话",
                lines: recentDialogue.map { entry in
                    let role = entry.kind == .user ? "用户" : "Agent"
                    return "- \(role)：\(singleLine(entry.content, limit: 1_600))"
                },
                limit: 10_500
            ))
        }

        if !fileChanges.isEmpty {
            let uniqueChanges = deduplicated(Array(fileChanges.suffix(30)).map(\.content))
            sections.append(section(
                title: "文件与代码状态",
                lines: uniqueChanges.map { "- \(singleLine($0, limit: 600))" },
                limit: 5_000
            ))
        }

        if !commands.isEmpty {
            let commandLines = Array(commands.suffix(20)).map { entry in
                var line = "- [exit \(entry.exitCode.map(String.init) ?? "?")] \(singleLine(entry.content, limit: 500))"
                if let exitCode = entry.exitCode, exitCode != 0,
                   let detail = entry.detail, !detail.isEmpty {
                    line += " | 错误摘要：\(singleLine(String(detail.suffix(900)), limit: 900))"
                }
                return line
            }
            sections.append(section(title: "最近命令", lines: commandLines, limit: 6_000))
        }

        if !issues.isEmpty {
            sections.append(section(
                title: "未解决问题与警告",
                lines: Array(issues.suffix(12)).map { "- \(singleLine($0.content, limit: 900))" },
                limit: 5_000
            ))
        }

        let attachmentPaths = deduplicated(relevantEntries.flatMap { entry in
            entry.attachments?.map(\.path) ?? []
        })
        if !attachmentPaths.isEmpty {
            sections.append(section(
                title: "用户附件",
                lines: attachmentPaths.suffix(20).map { "- \($0)" },
                limit: 4_000
            ))
        }

        sections.append("## 继续执行规则\n- 先响应当前用户请求，再按需检查仓库现状。\n- 保留精确路径、符号名、已确认决策和失败原因。\n- 不复述长日志；需要时重新运行小范围检查。\n- 若交接与工作区实际状态冲突，以当前工作区为准。")
        return String(sections.joined(separator: "\n\n").prefix(28_000))
    }

    private static func section(title: String, lines: [String], limit: Int) -> String {
        String(("## \(title)\n" + lines.joined(separator: "\n")).prefix(limit))
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return false }
            return true
        }
    }
}
