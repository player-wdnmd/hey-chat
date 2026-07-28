import Foundation

struct AgentHistoryStore {
    private let fileManager: FileManager
    private let archiveURL: URL

    init(fileManager: FileManager = .default, archiveURL: URL? = nil) {
        self.fileManager = fileManager
        if let archiveURL {
            self.archiveURL = archiveURL
        } else {
            let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.archiveURL = supportURL
                .appendingPathComponent("ChatMac", isDirectory: true)
                .appendingPathComponent("AgentHistory.json", isDirectory: false)
        }
    }

    func load() throws -> AgentHistoryArchive {
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            return AgentHistoryArchive()
        }
        let data = try Data(contentsOf: archiveURL)
        return try decoder.decode(AgentHistoryArchive.self, from: data)
    }

    func save(_ archive: AgentHistoryArchive) throws {
        let directoryURL = archiveURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(archive)
        try data.write(to: archiveURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
