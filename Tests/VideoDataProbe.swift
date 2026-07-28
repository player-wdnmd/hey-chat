import Foundation

@main
struct VideoDataProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMac-VideoDataProbe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let videoData = makeMP4Fixture()
        let store = VideoFileStore(
            rootDirectory: root.appendingPathComponent("Media", isDirectory: true),
            maximumFileSize: 1024
        )
        let recordID = UUID()
        let stored = try store.store(
            videoData: videoData,
            preferredMimeType: "application/octet-stream",
            recordID: recordID
        )
        guard stored.relativePath == "Videos/\(recordID.uuidString).mp4",
              stored.mimeType == "video/mp4",
              stored.byteCount == videoData.count,
              store.fileExists(relativePath: stored.relativePath),
              try Data(contentsOf: store.url(for: stored.relativePath)) == videoData else {
            throw ProbeError.outputStorageFailed
        }

        let exportURL = root.appendingPathComponent("export.mp4")
        try Data("old export".utf8).write(to: exportURL)
        try store.export(relativePath: stored.relativePath, to: exportURL)
        guard try Data(contentsOf: exportURL) == videoData else {
            throw ProbeError.exportFailed
        }
        do {
            try store.export(relativePath: stored.relativePath, to: store.url(for: stored.relativePath))
            throw ProbeError.sameExportAccepted
        } catch VideoFileStoreError.sameExportDestination {
            // Expected.
        }

        do {
            _ = try store.url(for: "../outside.mp4")
            throw ProbeError.pathTraversalAccepted
        } catch is VideoFileStoreError {
            // Expected.
        }

        let staged = try store.stageForDeletion(relativePath: stored.relativePath)
        guard !store.fileExists(relativePath: stored.relativePath),
              FileManager.default.fileExists(atPath: staged.stagingURL.path) else {
            throw ProbeError.stagingFailed
        }
        let imageStore = ImageFileStore(
            rootDirectory: root.appendingPathComponent("Media", isDirectory: true)
        )
        try imageStore.reconcileStaging(liveRelativePaths: [])
        guard FileManager.default.fileExists(atPath: staged.stagingURL.path) else {
            throw ProbeError.crossMediaStagingIsolationFailed
        }
        try store.reconcileStaging(liveRelativePaths: [stored.relativePath])
        guard store.fileExists(relativePath: stored.relativePath) else {
            throw ProbeError.restoreFailed
        }
        let stagedAgain = try store.stageForDeletion(relativePath: stored.relativePath)
        try store.reconcileStaging(liveRelativePaths: [])
        guard !store.fileExists(relativePath: stored.relativePath),
              !FileManager.default.fileExists(atPath: stagedAgain.stagingURL.path) else {
            throw ProbeError.discardFailed
        }

        let downloadedURL = root.appendingPathComponent("downloaded.tmp")
        try videoData.write(to: downloadedURL)
        let downloadedRecordID = UUID()
        let downloaded = try store.storeDownloadedVideo(
            at: downloadedURL,
            preferredMimeType: "video/mp4",
            recordID: downloadedRecordID
        )
        guard downloaded.relativePath == "Videos/\(downloadedRecordID.uuidString).mp4",
              !FileManager.default.fileExists(atPath: downloadedURL.path),
              store.fileExists(relativePath: downloaded.relativePath) else {
            throw ProbeError.downloadedFileStorageFailed
        }

        do {
            _ = try store.store(
                videoData: Data("not a video".utf8),
                preferredMimeType: "video/mp4",
                recordID: UUID()
            )
            throw ProbeError.invalidVideoAccepted
        } catch VideoFileStoreError.invalidVideo {
            // Expected.
        }

        let limitedStore = VideoFileStore(
            rootDirectory: root.appendingPathComponent("LimitedMedia", isDirectory: true),
            maximumFileSize: 8
        )
        do {
            _ = try limitedStore.store(
                videoData: videoData,
                preferredMimeType: "video/mp4",
                recordID: UUID()
            )
            throw ProbeError.oversizedVideoAccepted
        } catch VideoFileStoreError.fileTooLarge(8) {
            // Expected.
        }

        print("Video data probe passed")
    }

    private static func makeMP4Fixture() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("isom".utf8))
        data.append(Data([0x00, 0x00, 0x00, 0x00]))
        data.append(Data("isom".utf8))
        data.append(Data("mp42".utf8))
        return data
    }
}

private enum ProbeError: Error {
    case outputStorageFailed
    case exportFailed
    case sameExportAccepted
    case pathTraversalAccepted
    case stagingFailed
    case crossMediaStagingIsolationFailed
    case restoreFailed
    case discardFailed
    case downloadedFileStorageFailed
    case invalidVideoAccepted
    case oversizedVideoAccepted
}
