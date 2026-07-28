import Combine
import Foundation
import SwiftData

@MainActor
final class VideoGenerationCoordinator: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var requestStartedAt: Date?
    @Published var activeRecordID: UUID?
    @Published var status: VideoWorkspaceStatus?

    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private let videoService: VideoService
    private let fileStore: VideoFileStore

    init() {
        self.videoService = VideoService()
        self.fileStore = VideoFileStore()
    }

    init(videoService: VideoService, fileStore: VideoFileStore) {
        self.videoService = videoService
        self.fileStore = fileStore
    }

    @discardableResult
    func start(
        request: VideoToolRequest,
        target: VideoModelTarget,
        prompt: String,
        modelContext: ModelContext
    ) -> Bool {
        guard requestTask == nil else { return false }

        let newRequestID = UUID()
        let recordID = UUID()
        requestID = newRequestID
        requestStartedAt = .now
        isBusy = true
        status = nil

        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == newRequestID {
                    requestTask = nil
                    requestID = nil
                    requestStartedAt = nil
                    isBusy = false
                }
            }

            do {
                let result = try await videoService.perform(
                    request,
                    target: target,
                    recordID: recordID
                )
                guard !Task.isCancelled, requestID == newRequestID else {
                    try? fileStore.remove(relativePath: result.localRelativePath)
                    return
                }

                let record = MediaRecord(
                    id: recordID,
                    mediaKind: .video,
                    operation: .videoGenerate,
                    prompt: prompt,
                    modelIdentifier: target.modelIdentifier,
                    modelDisplayName: target.displayName,
                    localRelativePath: result.localRelativePath,
                    resultSummary: result.resultSummary,
                    responseJSON: result.responseJSON
                )
                modelContext.insert(record)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    try? fileStore.remove(relativePath: result.localRelativePath)
                    throw error
                }

                activeRecordID = record.id
                status = .success("视频已保存到本机媒体库。")
            } catch is CancellationError {
                guard requestID == newRequestID else { return }
                status = .success("视频请求已取消。")
            } catch {
                guard requestID == newRequestID else { return }
                status = .failure(error.localizedDescription)
            }
        }
        return true
    }

    func cancel(showStatus: Bool) {
        guard requestTask != nil else { return }
        requestTask?.cancel()
        if showStatus {
            status = .success("正在取消视频请求。")
        }
    }
}

struct VideoWorkspaceStatus {
    let message: String
    let isError: Bool

    static func success(_ message: String) -> VideoWorkspaceStatus {
        VideoWorkspaceStatus(message: message, isError: false)
    }

    static func failure(_ message: String) -> VideoWorkspaceStatus {
        VideoWorkspaceStatus(message: message, isError: true)
    }
}
