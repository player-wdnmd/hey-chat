import Foundation
import UniformTypeIdentifiers

struct StoredVideoFile: Sendable {
    let relativePath: String
    let mimeType: String
    let byteCount: Int
}

struct StagedVideoFile: Sendable {
    let originalRelativePath: String
    let stagingURL: URL
}

enum VideoDataInspector {
    static func detectedMimeType(
        for data: Data,
        preferredMimeType: String? = nil
    ) throws -> String {
        guard !data.isEmpty else {
            throw VideoFileStoreError.emptyFile
        }

        if isISOBaseMedia(data) {
            let brand = asciiString(in: data, range: 8..<12)?.lowercased()
            if brand == "qt  " {
                return "video/quicktime"
            }
            if brand == "m4v " || brand == "m4vh" || brand == "m4vp" {
                return "video/x-m4v"
            }
            return "video/mp4"
        }
        if data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return "video/webm"
        }
        if data.starts(with: Array("OggS".utf8)) {
            return "video/ogg"
        }
        if data.count >= 12,
           asciiString(in: data, range: 0..<4) == "RIFF",
           asciiString(in: data, range: 8..<12) == "AVI " {
            return "video/x-msvideo"
        }
        if data.starts(with: [0x00, 0x00, 0x01, 0xBA])
            || data.starts(with: [0x00, 0x00, 0x01, 0xB3]) {
            return "video/mpeg"
        }

        if let preferredMimeType = normalizedVideoMimeType(preferredMimeType),
           let type = UTType(mimeType: preferredMimeType),
           type.conforms(to: .movie) {
            throw VideoFileStoreError.invalidVideo
        }
        throw VideoFileStoreError.invalidVideo
    }

    static func detectedMimeType(
        forFileAt url: URL,
        preferredMimeType: String? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        guard let header = try handle.read(upToCount: 64), !header.isEmpty else {
            throw VideoFileStoreError.emptyFile
        }
        return try detectedMimeType(for: header, preferredMimeType: preferredMimeType)
    }

    private static func isISOBaseMedia(_ data: Data) -> Bool {
        data.count >= 12 && asciiString(in: data, range: 4..<8) == "ftyp"
    }

    private static func asciiString(in data: Data, range: Range<Int>) -> String? {
        guard data.count >= range.upperBound else { return nil }
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    private static func normalizedVideoMimeType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, normalized.hasPrefix("video/") else { return nil }
        return normalized
    }
}

struct VideoFileStore {
    static let defaultMaximumFileSize = 256 * 1024 * 1024

    private let rootDirectoryOverride: URL?
    private let fileManager: FileManager
    private let maximumFileSize: Int

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumFileSize: Int = defaultMaximumFileSize
    ) {
        self.rootDirectoryOverride = rootDirectory
        self.fileManager = fileManager
        self.maximumFileSize = max(1, maximumFileSize)
    }

    func store(
        videoData: Data,
        preferredMimeType: String?,
        recordID: UUID
    ) throws -> StoredVideoFile {
        guard !videoData.isEmpty else {
            throw VideoFileStoreError.emptyFile
        }
        guard videoData.count <= maximumFileSize else {
            throw VideoFileStoreError.fileTooLarge(maximumFileSize)
        }

        let mimeType = try VideoDataInspector.detectedMimeType(
            for: videoData,
            preferredMimeType: preferredMimeType
        )
        let relativePath = "Videos/\(recordID.uuidString).\(fileExtension(for: mimeType))"
        let destination = try url(for: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try videoData.write(to: destination, options: .atomic)
        return StoredVideoFile(
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: videoData.count
        )
    }

    func storeDownloadedVideo(
        at temporaryURL: URL,
        preferredMimeType: String?,
        recordID: UUID
    ) throws -> StoredVideoFile {
        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw VideoFileStoreError.emptyFile
        }
        guard byteCount <= maximumFileSize else {
            throw VideoFileStoreError.fileTooLarge(maximumFileSize)
        }

        let mimeType = try VideoDataInspector.detectedMimeType(
            forFileAt: temporaryURL,
            preferredMimeType: preferredMimeType
        )
        let relativePath = "Videos/\(recordID.uuidString).\(fileExtension(for: mimeType))"
        let destination = try url(for: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destination)
            try? fileManager.removeItem(at: temporaryURL)
        }
        return StoredVideoFile(
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: byteCount
        )
    }

    func url(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else {
            throw VideoFileStoreError.invalidRelativePath
        }

        let root = try rootDirectory()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw VideoFileStoreError.invalidRelativePath
        }
        return candidate
    }

    func remove(relativePath: String) throws {
        let target = try url(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    func stageForDeletion(relativePath: String) throws -> StagedVideoFile {
        let source = try url(for: relativePath)
        let stagingDirectory = try url(for: ".Trash")
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let stagingURL = stagingDirectory
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        try fileManager.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.moveItem(at: source, to: stagingURL)
        return StagedVideoFile(originalRelativePath: relativePath, stagingURL: stagingURL)
    }

    func restore(_ stagedFile: StagedVideoFile) throws {
        let destination = try url(for: stagedFile.originalRelativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        guard fileManager.fileExists(atPath: stagedFile.stagingURL.path) else { return }
        try fileManager.moveItem(at: stagedFile.stagingURL, to: destination)
    }

    func discard(_ stagedFile: StagedVideoFile) throws {
        guard fileManager.fileExists(atPath: stagedFile.stagingURL.path) else { return }
        try fileManager.removeItem(at: stagedFile.stagingURL)
    }

    func reconcileStaging(liveRelativePaths: [String]) throws {
        let mediaDirectoryName = "Videos"
        let stagingDirectory = try url(for: ".Trash/\(mediaDirectoryName)")
        guard fileManager.fileExists(atPath: stagingDirectory.path) else { return }

        let livePaths = Set(liveRelativePaths)
        let enumerator = fileManager.enumerator(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        var stagedFiles: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            stagedFiles.append(fileURL)
        }

        let resolvedStagingDirectory = stagingDirectory.resolvingSymlinksInPath()
        let stagingPrefix = resolvedStagingDirectory.path + "/"
        for stagingURL in stagedFiles {
            let resolvedStagingURL = stagingURL.resolvingSymlinksInPath()
            guard resolvedStagingURL.path.hasPrefix(stagingPrefix) else { continue }
            let stagedRelativePath = String(resolvedStagingURL.path.dropFirst(stagingPrefix.count))
            let relativePath = "\(mediaDirectoryName)/\(stagedRelativePath)"

            guard livePaths.contains(relativePath) else {
                try? fileManager.removeItem(at: resolvedStagingURL)
                continue
            }

            let destination = try url(for: relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: resolvedStagingURL)
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fileManager.moveItem(at: resolvedStagingURL, to: destination)
        }
    }

    func export(relativePath: String, to destination: URL) throws {
        let source = try url(for: relativePath).standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source != destination else {
            throw VideoFileStoreError.sameExportDestination
        }

        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".ChatMac-video-export-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try fileManager.copyItem(at: source, to: temporaryURL)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }

    func fileExists(relativePath: String) -> Bool {
        guard let target = try? url(for: relativePath) else { return false }
        return fileManager.fileExists(atPath: target.path)
    }

    private func rootDirectory() throws -> URL {
        if let rootDirectoryOverride {
            try fileManager.createDirectory(
                at: rootDirectoryOverride,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return rootDirectoryOverride.standardizedFileURL
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("ChatMac", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        return root.standardizedFileURL
    }

    private func fileExtension(for mimeType: String) -> String {
        if let type = UTType(mimeType: mimeType),
           let extensionName = type.preferredFilenameExtension,
           !extensionName.isEmpty {
            return extensionName
        }
        return switch mimeType {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        case "video/webm": "webm"
        case "video/ogg": "ogv"
        case "video/x-msvideo": "avi"
        case "video/mpeg": "mpeg"
        default: "video"
        }
    }
}

enum VideoFileStoreError: LocalizedError {
    case emptyFile
    case invalidVideo
    case fileTooLarge(Int)
    case invalidRelativePath
    case sameExportDestination

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "视频文件为空。"
        case .invalidVideo:
            "无法读取有效的视频数据。"
        case .fileTooLarge(let maximumFileSize):
            "视频文件不能超过 \(maximumFileSize / 1024 / 1024) MB。"
        case .invalidRelativePath:
            "视频文件路径无效。"
        case .sameExportDestination:
            "导出位置不能与媒体库中的原视频相同。"
        }
    }
}
