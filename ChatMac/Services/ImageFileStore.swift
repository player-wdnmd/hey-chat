import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageInputFile: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let mimeType: String
    let data: Data

    init(
        id: UUID = UUID(),
        fileName: String,
        mimeType: String,
        data: Data
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

enum ImageInputLoader {
    static let maximumFileSize = 10 * 1024 * 1024
    static let maximumFileCount = 5
    static let supportedMimeTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/webp",
    ]

    static func load(url: URL) throws -> ImageInputFile {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > maximumFileSize {
            throw ImageFileStoreError.inputTooLarge(maximumFileSize)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw ImageFileStoreError.emptyFile
        }
        guard data.count <= maximumFileSize else {
            throw ImageFileStoreError.inputTooLarge(maximumFileSize)
        }

        let mimeType = try detectedMimeType(for: data, requiringSupportedInputType: true)
        return ImageInputFile(
            fileName: url.lastPathComponent.isEmpty ? "image" : url.lastPathComponent,
            mimeType: mimeType,
            data: data
        )
    }

    static func detectedMimeType(
        for data: Data,
        requiringSupportedInputType: Bool = false
    ) throws -> String {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let type = CGImageSourceGetType(imageSource) else {
            throw ImageFileStoreError.invalidImage
        }

        let identifier = type as String
        guard let mimeType = UTType(identifier)?.preferredMIMEType,
              mimeType.hasPrefix("image/") else {
            throw ImageFileStoreError.invalidImage
        }
        if requiringSupportedInputType && !supportedMimeTypes.contains(mimeType) {
            throw ImageFileStoreError.unsupportedInputType(mimeType)
        }
        return mimeType
    }
}

struct StoredImageFile: Sendable {
    let relativePath: String
    let mimeType: String
    let byteCount: Int
}

struct StagedImageFile: Sendable {
    let originalRelativePath: String
    let stagingURL: URL
}

struct ImageFileStore {
    private let rootDirectoryOverride: URL?
    private let fileManager: FileManager

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryOverride = rootDirectory
        self.fileManager = fileManager
    }

    func store(
        imageData: Data,
        preferredMimeType _: String?,
        recordID: UUID
    ) throws -> StoredImageFile {
        let mimeType = try ImageInputLoader.detectedMimeType(for: imageData)
        let relativePath = "Images/\(recordID.uuidString).\(fileExtension(for: mimeType))"
        let destination = try url(for: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try imageData.write(to: destination, options: .atomic)
        return StoredImageFile(
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: imageData.count
        )
    }

    func url(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else {
            throw ImageFileStoreError.invalidRelativePath
        }

        let root = try rootDirectory()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw ImageFileStoreError.invalidRelativePath
        }
        return candidate
    }

    func remove(relativePath: String) throws {
        let target = try url(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    func stageForDeletion(relativePath: String) throws -> StagedImageFile {
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
        return StagedImageFile(originalRelativePath: relativePath, stagingURL: stagingURL)
    }

    func restore(_ stagedFile: StagedImageFile) throws {
        let destination = try url(for: stagedFile.originalRelativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        guard fileManager.fileExists(atPath: stagedFile.stagingURL.path) else { return }
        try fileManager.moveItem(at: stagedFile.stagingURL, to: destination)
    }

    func discard(_ stagedFile: StagedImageFile) throws {
        guard fileManager.fileExists(atPath: stagedFile.stagingURL.path) else { return }
        try fileManager.removeItem(at: stagedFile.stagingURL)
    }

    func reconcileStaging(liveRelativePaths: [String]) throws {
        let mediaDirectoryName = "Images"
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
            throw ImageFileStoreError.sameExportDestination
        }

        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".ChatMac-export-\(UUID().uuidString)")
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
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        default: "image"
        }
    }
}

enum ImageFileStoreError: LocalizedError {
    case emptyFile
    case invalidImage
    case unsupportedInputType(String)
    case inputTooLarge(Int)
    case invalidRelativePath
    case sameExportDestination

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "图片文件为空。"
        case .invalidImage:
            "无法读取有效的图片数据。"
        case .unsupportedInputType(let mimeType):
            "仅支持 PNG、JPEG 或 WebP 图片，当前文件是 \(mimeType)。"
        case .inputTooLarge(let maximumFileSize):
            "单张图片不能超过 \(maximumFileSize / 1024 / 1024) MB。"
        case .invalidRelativePath:
            "图片文件路径无效。"
        case .sameExportDestination:
            "导出位置不能与媒体库中的原图相同。"
        }
    }
}
