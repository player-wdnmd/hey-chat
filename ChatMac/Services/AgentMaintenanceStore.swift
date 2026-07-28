import Foundation

struct AgentBackupPayload: Codable, Sendable {
    nonisolated static let schemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let archive: AgentHistoryArchive
    let personalPreferences: AgentPersonalPreferences

    nonisolated init(
        schemaVersion: Int = AgentBackupPayload.schemaVersion,
        createdAt: Date = .now,
        archive: AgentHistoryArchive,
        personalPreferences: AgentPersonalPreferences
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.archive = archive
        self.personalPreferences = personalPreferences
    }
}

enum AgentHealthSeverity: String, Sendable {
    case healthy
    case notice
    case warning

    var systemImage: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .notice: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

struct AgentHealthCheck: Identifiable, Sendable {
    let id = UUID()
    let severity: AgentHealthSeverity
    let title: String
    let detail: String
}

struct AgentMaintenanceStore {
    private let fileManager: FileManager
    private let historyStore: AgentHistoryStore

    init(fileManager: FileManager = .default, historyStore: AgentHistoryStore = AgentHistoryStore()) {
        self.fileManager = fileManager
        self.historyStore = historyStore
    }

    func writeBackup(_ payload: AgentBackupPayload, to url: URL) throws {
        let destination = url.pathExtension.isEmpty
            ? url.appendingPathExtension("heychat-agent-backup")
            : url
        let directoryURL = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encodedData(payload).write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func readBackup(from url: URL) throws -> AgentBackupPayload {
        let payload = try decoder.decode(AgentBackupPayload.self, from: Data(contentsOf: url))
        guard payload.schemaVersion <= AgentBackupPayload.schemaVersion else {
            throw AgentMaintenanceError.unsupportedBackupVersion(payload.schemaVersion)
        }
        return payload
    }

    func createAutomaticBackup(
        archive: AgentHistoryArchive,
        personalPreferences: AgentPersonalPreferences
    ) throws -> URL {
        let backupDirectory = historyStore.storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("AgentBackups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = backupDirectory.appendingPathComponent(
            "AgentBackup-\(formatter.string(from: .now)).heychat-agent-backup",
            isDirectory: false
        )
        try writeBackup(
            AgentBackupPayload(archive: archive, personalPreferences: personalPreferences),
            to: url
        )
        return url
    }

    func healthChecks(for archive: AgentHistoryArchive) -> [AgentHealthCheck] {
        var checks: [AgentHealthCheck] = []
        let projects = archive.projects
        if projects.isEmpty {
            checks.append(AgentHealthCheck(
                severity: .notice,
                title: "尚未添加 Agent 项目",
                detail: "选择一个本机项目目录后，才能使用项目级记忆、资料库和执行记录。"
            ))
        } else {
            let unavailableProjects = projects.filter {
                !fileManager.fileExists(atPath: $0.path)
            }
            checks.append(AgentHealthCheck(
                severity: unavailableProjects.isEmpty ? .healthy : .warning,
                title: unavailableProjects.isEmpty ? "项目目录可用" : "存在不可用项目目录",
                detail: unavailableProjects.isEmpty
                    ? "已检查 \(projects.count) 个 Agent 项目。"
                    : "\(unavailableProjects.count) 个项目路径已不存在或不可访问；历史仍保留，可重新选择项目目录。"
            ))
        }

        let documents = projects.flatMap(\.localLibrary)
        let unavailableDocuments = documents.filter { !fileManager.fileExists(atPath: $0.path) }
        checks.append(AgentHealthCheck(
            severity: unavailableDocuments.isEmpty ? .healthy : .warning,
            title: unavailableDocuments.isEmpty ? "资料来源可用" : "存在不可用资料来源",
            detail: documents.isEmpty
                ? "当前尚未建立本地资料索引。"
                : unavailableDocuments.isEmpty
                    ? "\(documents.count) 份资料来源均可访问。"
                    : "\(unavailableDocuments.count) 份资料已移动或不可访问；在资料库中刷新或移除即可。"
        ))

        let openInbox = archive.inbox.filter { $0.status == .open }
        checks.append(AgentHealthCheck(
            severity: openInbox.isEmpty ? .healthy : .notice,
            title: openInbox.isEmpty ? "收件箱已清空" : "收件箱有待处理任务",
            detail: openInbox.isEmpty ? "没有未处理的临时任务。" : "当前有 \(openInbox.count) 项待办，可在 Agent 顶栏的收件箱中继续处理。"
        ))

        let historyExists = fileManager.fileExists(atPath: historyStore.storageURL.path)
        checks.append(AgentHealthCheck(
            severity: historyExists ? .healthy : .notice,
            title: historyExists ? "Agent 历史已持久化" : "Agent 历史尚未写入磁盘",
            detail: historyExists
                ? "历史文件位于 \(historyStore.storageURL.path)。"
                : "首次进行 Agent 操作后会自动创建本机历史文件。"
        ))
        return checks
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encodedData(_ payload: AgentBackupPayload) throws -> Data {
        try encoder.encode(payload)
    }
}

enum AgentMaintenanceError: LocalizedError {
    case unsupportedBackupVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedBackupVersion(let version):
            "该备份使用了较新的 Agent 备份格式（v\(version)），当前应用无法安全导入。"
        }
    }
}
