import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AgentContextCompactorProbe failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private struct AgentContextCompactorProbe {
static func main() throws {
let oldArchiveJSON = """
{
  "version": 1,
  "projects": [{
    "id": "00000000-0000-0000-0000-000000000001",
    "path": "/tmp/project",
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-01T00:00:00Z",
    "additionalWritablePaths": [],
    "sessions": [{
      "id": "00000000-0000-0000-0000-000000000002",
      "title": "旧会话",
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-01T00:00:00Z",
      "entries": []
    }]
  }]
}
"""
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let oldArchive = try decoder.decode(AgentHistoryArchive.self, from: Data(oldArchiveJSON.utf8))
require(oldArchive.projects.first?.sessions.first?.contextSummary == nil, "旧历史必须可解码")

let longSuccessfulOutput = String(repeating: "不应进入交接摘要", count: 8_000)
let entries: [AgentTranscriptEntry] = [
    .user("保留原来的界面风格，并完成 Agent 上下文压缩。"),
    .assistant("已经定位到 Agent 发送链路。"),
    .command(command: "xcodebuild build", output: longSuccessfulOutput, exitCode: 0),
    .user("继续处理，并确保旧历史兼容。"),
    .completion(
        durationMilliseconds: 100,
        inputTokens: 125_000,
        outputTokens: 2_000,
        currentStep: nil,
        totalSteps: nil,
        changedFiles: 1,
        addedLines: 10,
        deletedLines: 0
    ),
]
let session = AgentSessionRecord(
    threadID: "thread-old",
    entries: entries,
    lastInputTokens: 125_000
)
let plan = AgentContextCompactor.compactionPlan(
    for: session,
    projectPath: "/tmp/project",
    engine: .codexCLI,
    pendingPrompt: "下一步"
)
require(plan != nil, "达到输入 token 高水位后应触发压缩")
require(plan?.summary.contains("保留原来的界面风格") == true, "必须保留用户约束")
require(plan?.summary.contains("不应进入交接摘要") == false, "成功命令的长输出必须省略")
require((plan?.summary.count ?? .max) <= 28_000, "交接摘要必须有硬上限")

let switchPlan = AgentContextCompactor.recoveryPlan(
    entries: entries + [.modelSwitch(to: "Claude 4.7", generation: 2)],
    projectPath: "/tmp/project",
    reason: "已切换到 Claude 4.7"
)
require(switchPlan.summary.contains("保留原来的界面风格"), "模型切换必须携带原用户约束")
require(switchPlan.summary.contains("已经定位到 Agent 发送链路"), "模型切换必须携带最近进展")
require(!switchPlan.summary.contains("模型已切换"), "切换状态事件不应污染交接摘要")

let shortSession = AgentSessionRecord(
    threadID: "thread-short",
    entries: [.user("第一轮"), .assistant("完成")]
)
require(
    AgentContextCompactor.compactionPlan(
        for: shortSession,
        projectPath: "/tmp/project",
        engine: .claudeCodeCLI,
        pendingPrompt: "第二轮"
    ) == nil,
    "短会话不应过早压缩"
)

print("AgentContextCompactorProbe passed")
}
}
