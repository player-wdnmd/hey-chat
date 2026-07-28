import Foundation
import UniformTypeIdentifiers

struct AgentLibraryDocument: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var path: String
    var displayName: String
    var isDirectory: Bool
    var contentTypeIdentifier: String?
    var byteSize: Int64?
    var indexedAt: Date
    var modifiedAt: Date?
    var indexedFileCount: Int
    // This is a bounded local search index. The original file is never copied into the app.
    var indexedText: String
    var securityScopedBookmark: Data?

    nonisolated init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        isDirectory: Bool,
        contentTypeIdentifier: String? = nil,
        byteSize: Int64? = nil,
        indexedAt: Date = .now,
        modifiedAt: Date? = nil,
        indexedFileCount: Int = 0,
        indexedText: String = "",
        securityScopedBookmark: Data? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteSize = byteSize
        self.indexedAt = indexedAt
        self.modifiedAt = modifiedAt
        self.indexedFileCount = indexedFileCount
        self.indexedText = indexedText
        self.securityScopedBookmark = securityScopedBookmark
    }

    nonisolated var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    nonisolated var kindDisplayName: String {
        isDirectory ? "文件夹" : "文件"
    }

    nonisolated var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    nonisolated func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(normalized)
            || path.localizedCaseInsensitiveContains(normalized)
            || indexedText.localizedCaseInsensitiveContains(normalized)
    }

    nonisolated func contextExcerpt(matching query: String, maximumCharacters: Int = 4_000) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = indexedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "未提取可检索文本；请按来源路径直接读取。" }
        guard !normalized.isEmpty,
              let range = text.range(of: normalized, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(maximumCharacters))
        }
        let prefixStart = text.index(range.lowerBound, offsetBy: -maximumCharacters / 3, limitedBy: text.startIndex)
            ?? text.startIndex
        let suffixEnd = text.index(range.upperBound, offsetBy: maximumCharacters * 2 / 3, limitedBy: text.endIndex)
            ?? text.endIndex
        return String(text[prefixStart..<suffixEnd])
    }
}

enum AgentInboxStatus: String, Codable, Hashable, Sendable {
    case open
    case completed

    var displayName: String {
        switch self {
        case .open: "待处理"
        case .completed: "已完成"
        }
    }
}

struct AgentInboxItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var detail: String
    var status: AgentInboxStatus
    var projectID: UUID?
    var createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        status: AgentInboxStatus = .open,
        projectID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
