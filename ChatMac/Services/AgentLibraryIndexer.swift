import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AgentLibraryIndexer {
    nonisolated private static let maximumIndexedCharacters = 350_000
    nonisolated private static let maximumFilesPerDirectory = 240
    nonisolated private static let maximumIndividualFileSize = 2_000_000

    nonisolated static func index(url: URL, existingID: UUID? = nil) throws -> AgentLibraryDocument {
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try standardizedURL.resourceValues(forKeys: [
            .isDirectoryKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let isDirectory = values.isDirectory == true
        let bookmark = try? standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let indexed = withSecurityScopedAccess(url: standardizedURL, bookmark: bookmark) { accessibleURL in
            (accessibleURL, isDirectory ? indexDirectory(accessibleURL) : indexFile(accessibleURL))
        }
        let accessibleURL = indexed.0.standardizedFileURL
        let indexedContent = indexed.1
        return AgentLibraryDocument(
            id: existingID ?? UUID(),
            path: accessibleURL.path,
            displayName: accessibleURL.lastPathComponent,
            isDirectory: isDirectory,
            contentTypeIdentifier: values.contentType?.identifier,
            byteSize: values.fileSize.map(Int64.init),
            indexedAt: .now,
            modifiedAt: values.contentModificationDate,
            indexedFileCount: indexedContent.fileCount,
            indexedText: indexedContent.text,
            securityScopedBookmark: bookmark
        )
    }

    nonisolated static func withSecurityScopedAccess<T>(
        url: URL,
        bookmark: Data?,
        body: (URL) throws -> T
    ) rethrows -> T {
        let resolvedURL: URL
        var bookmarkIsStale = false
        if let bookmark,
           let bookmarkURL = try? URL(
               resolvingBookmarkData: bookmark,
               options: [.withSecurityScope],
               relativeTo: nil,
               bookmarkDataIsStale: &bookmarkIsStale
           ) {
            resolvedURL = bookmarkURL
        } else {
            resolvedURL = url
        }
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { resolvedURL.stopAccessingSecurityScopedResource() }
        }
        return try body(resolvedURL)
    }

    private nonisolated static func indexDirectory(_ url: URL) -> (text: String, fileCount: Int) {
        let allowed = textFileExtensions
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ("", 0)
        }
        var fragments: [String] = []
        var textLength = 0
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            guard fileCount < maximumFilesPerDirectory,
                  textLength < maximumIndexedCharacters,
                  allowed.contains(fileURL.pathExtension.lowercased()),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maximumIndividualFileSize,
                  let content = readTextFile(fileURL), !content.isEmpty else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            let remaining = maximumIndexedCharacters - textLength
            let fragment = "\n\n--- \(relativePath) ---\n\(content.prefix(remaining))"
            fragments.append(fragment)
            textLength += fragment.count
            fileCount += 1
        }
        return (fragments.joined(), fileCount)
    }

    private nonisolated static func indexFile(_ url: URL) -> (text: String, fileCount: Int) {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
            return (String(text.prefix(maximumIndexedCharacters)), 1)
        }
        guard let content = readTextFile(url) else { return ("", 0) }
        return (String(content.prefix(maximumIndexedCharacters)), 1)
    }

    private nonisolated static func readTextFile(_ url: URL) -> String? {
        guard textFileExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= maximumIndividualFileSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
    }

    nonisolated private static let textFileExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "csv", "go", "h", "hpp", "html", "java", "js", "json",
        "jsx", "kt", "kts", "md", "m", "mm", "plist", "py", "rb", "rs", "sh", "sql", "swift",
        "toml", "ts", "tsx", "txt", "xml", "yaml", "yml",
    ]
}
