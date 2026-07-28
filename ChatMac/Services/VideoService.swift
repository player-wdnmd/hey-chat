import Foundation

extension VideoModelTarget {
    init(model: AIModelConfiguration) {
        self.init(
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            provider: model.provider,
            baseURLString: model.baseURLString,
            keychainAccount: model.keychainAccount
        )
    }
}

struct PersistedVideoResult: Sendable {
    let localRelativePath: String
    let resultSummary: String
    let responseJSON: String?
    let taskID: String?
}

struct VideoService {
    private let keychain: KeychainService
    private let client: VideoAPIClient
    private let fileStore: VideoFileStore

    init(
        keychain: KeychainService = KeychainService(),
        client: VideoAPIClient = VideoAPIClient(),
        fileStore: VideoFileStore = VideoFileStore()
    ) {
        self.keychain = keychain
        self.client = client
        self.fileStore = fileStore
    }

    func perform(
        _ request: VideoToolRequest,
        target: VideoModelTarget,
        recordID: UUID
    ) async throws -> PersistedVideoResult {
        guard target.provider == .openAICompatible else {
            throw VideoAPIError.unsupportedProvider
        }

        let storedKey = try keychain.read(account: target.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = storedKey.flatMap { $0.isEmpty ? nil : $0 }
        let response = try await client.perform(request, target: target, apiKey: apiKey)
        let storedFile: StoredVideoFile
        switch response.content {
        case .data(let data):
            storedFile = try fileStore.store(
                videoData: data,
                preferredMimeType: response.mimeType,
                recordID: recordID
            )
        case .temporaryFile(let url, _):
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            storedFile = try fileStore.storeDownloadedVideo(
                at: url,
                preferredMimeType: response.mimeType,
                recordID: recordID
            )
        }
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(storedFile.byteCount),
            countStyle: .file
        )
        return PersistedVideoResult(
            localRelativePath: storedFile.relativePath,
            resultSummary: "\(response.resultSummary) · \(sizeText)",
            responseJSON: response.responseJSON,
            taskID: response.taskID
        )
    }
}
