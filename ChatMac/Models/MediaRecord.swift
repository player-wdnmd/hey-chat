import Foundation
import SwiftData

@Model
final class MediaRecord {
    @Attribute(.unique) var id: UUID
    var mediaKindRawValue: String
    var operationRawValue: String
    var prompt: String
    var modelIdentifier: String
    var modelDisplayName: String
    var localRelativePath: String
    var resultSummary: String
    var responseJSON: String?
    var sourceConversationID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        mediaKind: MediaKind,
        operation: MediaOperation,
        prompt: String,
        modelIdentifier: String,
        modelDisplayName: String,
        localRelativePath: String,
        resultSummary: String = "",
        responseJSON: String? = nil,
        sourceConversationID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.mediaKindRawValue = mediaKind.rawValue
        self.operationRawValue = operation.rawValue
        self.prompt = prompt
        self.modelIdentifier = modelIdentifier
        self.modelDisplayName = modelDisplayName
        self.localRelativePath = localRelativePath
        self.resultSummary = resultSummary
        self.responseJSON = responseJSON
        self.sourceConversationID = sourceConversationID
        self.createdAt = createdAt
    }

    var mediaKind: MediaKind {
        get { MediaKind(rawValue: mediaKindRawValue) ?? .image }
        set { mediaKindRawValue = newValue.rawValue }
    }

    var isImage: Bool {
        mediaKindRawValue == MediaKind.image.rawValue
    }

    var isVideo: Bool {
        mediaKindRawValue == MediaKind.video.rawValue
    }

    var operation: MediaOperation {
        get { MediaOperation(rawValue: operationRawValue) ?? .generate }
        set { operationRawValue = newValue.rawValue }
    }
}
