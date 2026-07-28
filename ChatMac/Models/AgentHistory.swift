import Foundation
import UniformTypeIdentifiers

struct AgentAttachmentRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let path: String
    let displayName: String
    let contentTypeIdentifier: String?
    let byteSize: Int64?

    nonisolated init(id: UUID = UUID(), url: URL) {
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        self.id = id
        self.path = standardizedURL.path
        self.displayName = standardizedURL.lastPathComponent
        self.contentTypeIdentifier = values?.contentType?.identifier
            ?? UTType(filenameExtension: standardizedURL.pathExtension)?.identifier
        self.byteSize = values?.fileSize.map(Int64.init)
    }

    nonisolated init(
        id: UUID,
        path: String,
        displayName: String,
        contentTypeIdentifier: String?,
        byteSize: Int64?
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteSize = byteSize
    }

    nonisolated var url: URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    nonisolated var isImage: Bool {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier) else { return false }
        return contentType.conforms(to: .image)
    }
}

struct AgentHistoryArchive: Codable {
    var version = 6
    var selectedProjectID: UUID?
    var selectedSessionID: UUID?
    var projects: [AgentProjectRecord] = []
    // Optional so archives written before the global Agent inbox was introduced keep decoding.
    var inboxItems: [AgentInboxItem]?

    var inbox: [AgentInboxItem] {
        inboxItems ?? []
    }
}

struct AgentProjectRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var createdAt: Date
    var updatedAt: Date
    var additionalWritablePaths: [String]
    // Optional so archives written before project memory was introduced keep decoding.
    var memory: AgentProjectMemory?
    // Optional so archives written before project workflows were introduced keep decoding.
    var workflows: [AgentWorkflow]?
    // Optional so archives written before the local library was introduced keep decoding.
    var libraryDocuments: [AgentLibraryDocument]?
    var sessions: [AgentSessionRecord]

    var displayName: String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    init(
        id: UUID = UUID(),
        path: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        additionalWritablePaths: [String] = [],
        memory: AgentProjectMemory? = nil,
        workflows: [AgentWorkflow]? = nil,
        libraryDocuments: [AgentLibraryDocument]? = nil,
        sessions: [AgentSessionRecord] = []
    ) {
        self.id = id
        self.path = path
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.additionalWritablePaths = additionalWritablePaths
        self.memory = memory
        self.workflows = workflows
        self.libraryDocuments = libraryDocuments
        self.sessions = sessions
    }

    var customWorkflows: [AgentWorkflow] {
        workflows ?? []
    }

    var localLibrary: [AgentLibraryDocument] {
        libraryDocuments ?? []
    }
}

struct AgentSessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var threadID: String?
    var targetID: String?
    var entries: [AgentTranscriptEntry]
    var contextSummary: String?
    var contextHandoffPending: Bool?
    var lastCompactedAt: Date?
    var compactedEntryCount: Int?
    var contextGeneration: Int?
    var lastInputTokens: Int?
    // Optional so archives written before Agent run review was introduced keep decoding.
    var runs: [AgentRunRecord]?
    // Optional so archives written before Handoff Manifests were introduced keep decoding.
    var handoffs: [AgentHandoffManifest]?
    // Optional so archives written before library references were introduced keep decoding.
    var libraryDocumentIDs: [UUID]?

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        threadID: String? = nil,
        targetID: String? = nil,
        entries: [AgentTranscriptEntry] = [],
        contextSummary: String? = nil,
        contextHandoffPending: Bool? = nil,
        lastCompactedAt: Date? = nil,
        compactedEntryCount: Int? = nil,
        contextGeneration: Int? = nil,
        lastInputTokens: Int? = nil,
        runs: [AgentRunRecord]? = nil,
        handoffs: [AgentHandoffManifest]? = nil,
        libraryDocumentIDs: [UUID]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.threadID = threadID
        self.targetID = targetID
        self.entries = entries
        self.contextSummary = contextSummary
        self.contextHandoffPending = contextHandoffPending
        self.lastCompactedAt = lastCompactedAt
        self.compactedEntryCount = compactedEntryCount
        self.contextGeneration = contextGeneration
        self.lastInputTokens = lastInputTokens
        self.runs = runs
        self.handoffs = handoffs
        self.libraryDocumentIDs = libraryDocumentIDs
    }

    var latestPreview: String {
        let previewEntry = entries.reversed().first {
            $0.kind == .user || $0.kind == .assistant
        }
        guard let content = previewEntry?.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return "暂无消息"
        }
        return content.replacingOccurrences(of: "\n", with: " ")
    }

    var runRecords: [AgentRunRecord] {
        runs ?? []
    }

    var handoffManifests: [AgentHandoffManifest] {
        handoffs ?? []
    }

    var referencedLibraryDocumentIDs: [UUID] {
        libraryDocumentIDs ?? []
    }
}

enum AgentRunStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case restored

    var displayName: String {
        switch self {
        case .running: "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已停止"
        case .restored: "已恢复"
        }
    }
}

enum AgentRunFileChangeKind: String, Codable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case binary

    var displayName: String {
        switch self {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .binary: "二进制"
        }
    }
}

struct AgentRunFileChange: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let path: String
    let kind: AgentRunFileChangeKind
    let additions: Int
    let deletions: Int
    let patch: String?

    nonisolated init(
        id: UUID = UUID(),
        path: String,
        kind: AgentRunFileChangeKind,
        additions: Int = 0,
        deletions: Int = 0,
        patch: String? = nil
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}

struct AgentRunCheckpoint: Codable, Hashable, Sendable {
    let id: UUID
    let storagePath: String
    let workspacePath: String
    let repositoryPath: String
    let headRevision: String
    let baselineFingerprint: String
    var completedFingerprint: String?
    var restoredAt: Date?

    nonisolated var isRestored: Bool {
        restoredAt != nil
    }
}

struct AgentRunRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let taskSummary: String
    let targetID: String
    let modelName: String
    let channelName: String
    let engine: AgentEngineKind
    let startedAt: Date
    var completedAt: Date?
    var status: AgentRunStatus
    var checkpoint: AgentRunCheckpoint?
    var checkpointUnavailableReason: String?
    var files: [AgentRunFileChange]
    var additions: Int
    var deletions: Int
    var finalMessage: String?

    nonisolated init(
        id: UUID = UUID(),
        taskSummary: String,
        targetID: String,
        modelName: String,
        channelName: String,
        engine: AgentEngineKind,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        status: AgentRunStatus = .running,
        checkpoint: AgentRunCheckpoint? = nil,
        checkpointUnavailableReason: String? = nil,
        files: [AgentRunFileChange] = [],
        additions: Int = 0,
        deletions: Int = 0,
        finalMessage: String? = nil
    ) {
        self.id = id
        self.taskSummary = taskSummary
        self.targetID = targetID
        self.modelName = modelName
        self.channelName = channelName
        self.engine = engine
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.checkpoint = checkpoint
        self.checkpointUnavailableReason = checkpointUnavailableReason
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.finalMessage = finalMessage
    }
}

struct AgentTranscriptEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case user
        case assistant
        case command
        case fileChange
        case warning
        case error
        case contextCompact
        case modelSwitch
        case completion
    }

    let id: UUID
    let kind: Kind
    let title: String
    let content: String
    let detail: String?
    let exitCode: Int?
    let createdAt: Date
    let durationMilliseconds: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let currentStep: Int?
    let totalSteps: Int?
    let changedFiles: Int?
    let addedLines: Int?
    let deletedLines: Int?
    let attachments: [AgentAttachmentRecord]?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        content: String,
        detail: String?,
        exitCode: Int?,
        createdAt: Date = .now,
        durationMilliseconds: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        currentStep: Int? = nil,
        totalSteps: Int? = nil,
        changedFiles: Int? = nil,
        addedLines: Int? = nil,
        deletedLines: Int? = nil,
        attachments: [AgentAttachmentRecord]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.detail = detail
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.durationMilliseconds = durationMilliseconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.changedFiles = changedFiles
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.attachments = attachments
    }

    static func user(
        _ text: String,
        attachments: [AgentAttachmentRecord] = []
    ) -> AgentTranscriptEntry {
        AgentTranscriptEntry(
            kind: .user,
            title: "You",
            content: text,
            detail: nil,
            exitCode: nil,
            attachments: attachments.isEmpty ? nil : attachments
        )
    }

    static func assistant(_ text: String) -> AgentTranscriptEntry {
        AgentTranscriptEntry(kind: .assistant, title: "Agent", content: text, detail: nil, exitCode: nil)
    }

    static func command(command: String, output: String, exitCode: Int?) -> AgentTranscriptEntry {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumCharacters = 120_000
        let storedOutput: String
        if normalizedOutput.count > maximumCharacters {
            storedOutput = String(normalizedOutput.prefix(maximumCharacters))
                + "\n\n... 已省略 \(normalizedOutput.count - maximumCharacters) 个字符"
        } else {
            storedOutput = normalizedOutput
        }
        return AgentTranscriptEntry(
            kind: .command,
            title: "Terminal",
            content: command,
            detail: storedOutput,
            exitCode: exitCode
        )
    }

    static func fileChange(_ text: String) -> AgentTranscriptEntry {
        AgentTranscriptEntry(kind: .fileChange, title: "Files", content: text, detail: nil, exitCode: nil)
    }

    static func warning(_ text: String) -> AgentTranscriptEntry {
        AgentTranscriptEntry(kind: .warning, title: "Notice", content: text, detail: nil, exitCode: nil)
    }

    static func error(_ text: String) -> AgentTranscriptEntry {
        AgentTranscriptEntry(kind: .error, title: "Error", content: text, detail: nil, exitCode: nil)
    }

    static func contextCompact(generation: Int, reason: String) -> AgentTranscriptEntry {
        AgentTranscriptEntry(
            kind: .contextCompact,
            title: "上下文已压缩",
            content: "已切换到第 \(generation) 代 Agent 上下文 · \(reason)；完整聊天记录仍保留。",
            detail: nil,
            exitCode: nil
        )
    }

    static func modelSwitch(to modelName: String, generation: Int) -> AgentTranscriptEntry {
        AgentTranscriptEntry(
            kind: .modelSwitch,
            title: "模型已切换",
            content: "已切换到 \(modelName)，并携带第 \(generation) 代会话上下文继续当前任务。",
            detail: nil,
            exitCode: nil
        )
    }

    static func completion(
        durationMilliseconds: Int,
        inputTokens: Int?,
        outputTokens: Int?,
        currentStep: Int?,
        totalSteps: Int?,
        changedFiles: Int,
        addedLines: Int,
        deletedLines: Int
    ) -> AgentTranscriptEntry {
        AgentTranscriptEntry(
            kind: .completion,
            title: "完成",
            content: "已处理",
            detail: nil,
            exitCode: nil,
            durationMilliseconds: durationMilliseconds,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            currentStep: currentStep,
            totalSteps: totalSteps,
            changedFiles: changedFiles,
            addedLines: addedLines,
            deletedLines: deletedLines
        )
    }
}
