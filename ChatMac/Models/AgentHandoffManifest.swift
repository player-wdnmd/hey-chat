import Foundation

enum AgentHandoffKind: String, Codable, Hashable, Sendable {
    case compaction
    case modelSwitch
    case recovery

    var displayName: String {
        switch self {
        case .compaction: "上下文压缩"
        case .modelSwitch: "模型切换"
        case .recovery: "会话恢复"
        }
    }

    var systemImage: String {
        switch self {
        case .compaction: "rectangle.compress.vertical"
        case .modelSwitch: "arrow.left.arrow.right"
        case .recovery: "arrow.clockwise"
        }
    }
}

struct AgentHandoffManifest: Codable, Identifiable, Hashable, Sendable {
    nonisolated static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let generation: Int
    let kind: AgentHandoffKind
    let reason: String
    let sourceEntryCount: Int
    let estimatedTokens: Int
    let sourceTargetID: String?
    let destinationTargetID: String?
    let destinationModelName: String?
    let createdAt: Date
    var deliveredAt: Date?
    let content: String

    nonisolated init(
        id: UUID = UUID(),
        schemaVersion: Int = AgentHandoffManifest.currentSchemaVersion,
        generation: Int,
        kind: AgentHandoffKind,
        reason: String,
        sourceEntryCount: Int,
        estimatedTokens: Int,
        sourceTargetID: String?,
        destinationTargetID: String?,
        destinationModelName: String?,
        createdAt: Date = .now,
        deliveredAt: Date? = nil,
        content: String
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.kind = kind
        self.reason = reason
        self.sourceEntryCount = sourceEntryCount
        self.estimatedTokens = estimatedTokens
        self.sourceTargetID = sourceTargetID
        self.destinationTargetID = destinationTargetID
        self.destinationModelName = destinationModelName
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.content = content
    }

    var isDelivered: Bool {
        deliveredAt != nil
    }
}
