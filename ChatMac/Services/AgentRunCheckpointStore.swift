import CryptoKit
import Foundation

/// Persists a Git working-tree baseline for one Agent run. The baseline includes
/// pre-existing tracked edits and untracked files, so a restore returns to the
/// user's exact pre-run state instead of simply resetting to HEAD.
struct AgentRunCheckpointStore: Sendable {
    nonisolated private let rootURL: URL

    nonisolated init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChatMac", isDirectory: true)
                .appendingPathComponent("AgentCheckpoints", isDirectory: true)
        }
    }

    nonisolated func beginRun(
        workspaceURL: URL,
        taskSummary: String,
        target: AgentProviderTarget
    ) -> AgentRunRecord {
        let record = AgentRunRecord(
            taskSummary: taskSummary,
            targetID: target.id,
            modelName: target.title,
            channelName: target.channelName,
            engine: target.engine
        )

        do {
            let checkpoint = try createCheckpoint(for: workspaceURL, runID: record.id)
            var result = record
            result.checkpoint = checkpoint
            return result
        } catch {
            var result = record
            result.checkpointUnavailableReason = error.localizedDescription
            return result
        }
    }

    nonisolated func finishRun(
        _ record: AgentRunRecord,
        workspaceURL: URL,
        status: AgentRunStatus,
        finalMessage: String? = nil
    ) -> AgentRunRecord {
        var result = record
        result.status = status
        result.completedAt = .now
        result.finalMessage = finalMessage

        guard var checkpoint = result.checkpoint else { return result }
        do {
            let report = try makeRunDiff(checkpoint: checkpoint, workspaceURL: workspaceURL)
            checkpoint.completedFingerprint = report.fingerprint
            result.checkpoint = checkpoint
            result.files = report.files
            result.additions = report.files.reduce(0) { $0 + $1.additions }
            result.deletions = report.files.reduce(0) { $0 + $1.deletions }
        } catch {
            result.checkpointUnavailableReason = "本轮差异读取失败：\(error.localizedDescription)"
        }
        return result
    }

    nonisolated func canRestore(_ record: AgentRunRecord, workspaceURL: URL) -> Result<Void, Error> {
        guard let checkpoint = record.checkpoint else {
            return .failure(CheckpointError.unavailable(record.checkpointUnavailableReason))
        }
        guard !checkpoint.isRestored else {
            return .failure(CheckpointError.alreadyRestored)
        }
        guard checkpoint.workspacePath == workspaceURL.standardizedFileURL.path else {
            return .failure(CheckpointError.workspaceChanged)
        }
        do {
            let currentHead = try gitText(["rev-parse", "HEAD"], at: URL(fileURLWithPath: checkpoint.repositoryPath))
            guard currentHead == checkpoint.headRevision else {
                return .failure(CheckpointError.headChanged)
            }
            guard let completedFingerprint = checkpoint.completedFingerprint else {
                return .failure(CheckpointError.incomplete)
            }
            let fingerprint = try workingTreeFingerprint(at: URL(fileURLWithPath: checkpoint.repositoryPath))
            guard fingerprint == completedFingerprint else {
                return .failure(CheckpointError.workspaceChangedAfterRun)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    nonisolated func restore(_ record: AgentRunRecord, workspaceURL: URL) throws -> AgentRunRecord {
        switch canRestore(record, workspaceURL: workspaceURL) {
        case .success:
            break
        case .failure(let error):
            throw error
        }
        guard var checkpoint = record.checkpoint else {
            throw CheckpointError.unavailable(record.checkpointUnavailableReason)
        }
        let repositoryURL = URL(fileURLWithPath: checkpoint.repositoryPath, isDirectory: true)
        let storageURL = URL(fileURLWithPath: checkpoint.storagePath, isDirectory: true)
        let baselineIndexPatchURL = storageURL.appendingPathComponent("baseline-index.patch", isDirectory: false)
        let baselineWorktreePatchURL = storageURL.appendingPathComponent("baseline-worktree.patch", isDirectory: false)
        let baselineUntrackedURL = storageURL.appendingPathComponent("untracked", isDirectory: true)
        let baselineFiles = try readUntrackedManifest(at: storageURL)

        try runGit(["reset", "--hard", checkpoint.headRevision], at: repositoryURL)
        let currentUntracked = try untrackedFiles(at: repositoryURL)
        let baselinePaths = Set(baselineFiles.map(\.path))
        for path in currentUntracked.map(\.path) where !baselinePaths.contains(path) {
            try removeRelativePath(path, from: repositoryURL)
        }

        if FileManager.default.fileExists(atPath: baselineIndexPatchURL.path),
           let size = try? baselineIndexPatchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 {
            try runGit(["apply", "--index", "--binary", "--whitespace=nowarn", baselineIndexPatchURL.path], at: repositoryURL)
        }
        if FileManager.default.fileExists(atPath: baselineWorktreePatchURL.path),
           let size = try? baselineWorktreePatchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 {
            try runGit(["apply", "--binary", "--whitespace=nowarn", baselineWorktreePatchURL.path], at: repositoryURL)
        }
        for file in baselineFiles {
            let sourceURL = baselineUntrackedURL.appendingPathComponent(file.path, isDirectory: false)
            let destinationURL = repositoryURL.appendingPathComponent(file.path, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        let restoredFingerprint = try workingTreeFingerprint(at: repositoryURL)
        guard restoredFingerprint == checkpoint.baselineFingerprint else {
            throw CheckpointError.restoreVerificationFailed
        }

        checkpoint.restoredAt = .now
        var restoredRecord = record
        restoredRecord.status = .restored
        restoredRecord.checkpoint = checkpoint
        restoredRecord.finalMessage = "已恢复到本次 Agent 运行前的工作区状态。"
        return restoredRecord
    }

    nonisolated private func createCheckpoint(for workspaceURL: URL, runID: UUID) throws -> AgentRunCheckpoint {
        let repositoryPath = try gitText(["rev-parse", "--show-toplevel"], at: workspaceURL)
        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL
        let headRevision = try gitText(["rev-parse", "HEAD"], at: repositoryURL)
        let storageURL = rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        let indexPatch = try gitData(["diff", "--cached", "--binary", "--full-index", "HEAD", "--"], at: repositoryURL)
        try indexPatch.write(to: storageURL.appendingPathComponent("baseline-index.patch"), options: [.atomic])
        let worktreePatch = try gitData(["diff", "--binary", "--full-index", "--"], at: repositoryURL)
        try worktreePatch.write(to: storageURL.appendingPathComponent("baseline-worktree.patch"), options: [.atomic])

        let files = try untrackedFiles(at: repositoryURL)
        let untrackedURL = storageURL.appendingPathComponent("untracked", isDirectory: true)
        try FileManager.default.createDirectory(at: untrackedURL, withIntermediateDirectories: true)
        for file in files {
            let sourceURL = repositoryURL.appendingPathComponent(file.path, isDirectory: false)
            let destinationURL = untrackedURL.appendingPathComponent(file.path, isDirectory: false)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        try writeUntrackedManifest(files, at: storageURL)

        return AgentRunCheckpoint(
            id: runID,
            storagePath: storageURL.path,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryPath: repositoryURL.path,
            headRevision: headRevision,
            baselineFingerprint: try workingTreeFingerprint(at: repositoryURL)
        )
    }

    nonisolated private func makeRunDiff(
        checkpoint: AgentRunCheckpoint,
        workspaceURL: URL
    ) throws -> AgentRunDiffReport {
        let repositoryURL = URL(fileURLWithPath: checkpoint.repositoryPath, isDirectory: true)
        guard workspaceURL.standardizedFileURL.path == checkpoint.workspacePath else {
            throw CheckpointError.workspaceChanged
        }
        let storageURL = URL(fileURLWithPath: checkpoint.storagePath, isDirectory: true)
        let indexPatchURL = storageURL.appendingPathComponent("baseline-index.patch", isDirectory: false)
        let worktreePatchURL = storageURL.appendingPathComponent("baseline-worktree.patch", isDirectory: false)
        let temporaryIndexURL = storageURL.appendingPathComponent("baseline-index", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporaryIndexURL) }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_INDEX_FILE"] = temporaryIndexURL.path
        try runGit(["read-tree", checkpoint.headRevision], at: repositoryURL, environment: environment)
        if let size = try? indexPatchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try runGit(["apply", "--cached", "--binary", "--whitespace=nowarn", indexPatchURL.path], at: repositoryURL, environment: environment)
        }
        if let size = try? worktreePatchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try runGit(["apply", "--cached", "--binary", "--whitespace=nowarn", worktreePatchURL.path], at: repositoryURL, environment: environment)
        }
        let patch = String(data: try gitData(["diff", "--binary", "--full-index", "--"], at: repositoryURL, environment: environment), encoding: .utf8) ?? ""
        let numstat = String(data: try gitData(["diff", "--numstat", "--"], at: repositoryURL, environment: environment), encoding: .utf8) ?? ""
        var files = trackedDiffFiles(patch: patch, numstat: numstat)

        let baselineFiles = try readUntrackedManifest(at: storageURL)
        let currentFiles = try untrackedFiles(at: repositoryURL)
        let baselineByPath = Dictionary(uniqueKeysWithValues: baselineFiles.map { ($0.path, $0) })
        let currentByPath = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.path, $0) })
        let allPaths = Set(baselineByPath.keys).union(currentByPath.keys)
        let baselineUntrackedURL = storageURL.appendingPathComponent("untracked", isDirectory: true)

        for path in allPaths.sorted() {
            let baseline = baselineByPath[path]
            let current = currentByPath[path]
            guard baseline?.digest != current?.digest else { continue }
            let kind: AgentRunFileChangeKind
            if case .none = baseline { kind = .added }
            else if case .none = current { kind = .deleted }
            else { kind = .modified }

            let oldURL = baseline.map { baselineUntrackedURL.appendingPathComponent($0.path) }
            let newURL = current.map { repositoryURL.appendingPathComponent($0.path) }
            let diff = noIndexDiff(oldURL: oldURL, newURL: newURL)
            let stats = lineStats(oldURL: oldURL, newURL: newURL)
            files.append(AgentRunFileChange(
                path: path,
                kind: diff.isBinary ? .binary : kind,
                additions: stats.additions,
                deletions: stats.deletions,
                patch: diff.text
            ))
        }

        let deduplicated = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { _, later in later })
        return AgentRunDiffReport(
            files: deduplicated.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            fingerprint: try workingTreeFingerprint(at: repositoryURL)
        )
    }

    nonisolated private func trackedDiffFiles(patch: String, numstat: String) -> [AgentRunFileChange] {
        let stats = parseNumstat(numstat)
        return splitGitPatch(patch).compactMap { section in
            guard let path = pathFromPatch(section) else { return nil }
            let pathStats = stats[path] ?? (0, 0, false)
            let kind: AgentRunFileChangeKind
            if pathStats.binary || section.contains("Binary files ") { kind = .binary }
            else if section.contains("new file mode") { kind = .added }
            else if section.contains("deleted file mode") { kind = .deleted }
            else { kind = .modified }
            return AgentRunFileChange(
                path: path,
                kind: kind,
                additions: pathStats.additions,
                deletions: pathStats.deletions,
                patch: section
            )
        }
    }

    nonisolated private func splitGitPatch(_ patch: String) -> [String] {
        patch.components(separatedBy: "diff --git ").dropFirst().map { "diff --git " + $0 }
    }

    nonisolated private func pathFromPatch(_ section: String) -> String? {
        guard let firstLine = section.split(separator: "\n", maxSplits: 1).first else { return nil }
        let values = firstLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard values.count >= 4 else { return nil }
        let path = String(values[3])
        return path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    nonisolated private func parseNumstat(_ text: String) -> [String: (additions: Int, deletions: Int, binary: Bool)] {
        Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let path = String(parts[2])
            let binary = parts[0] == "-" || parts[1] == "-"
            return (path, (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, binary))
        })
    }

    nonisolated private func untrackedFiles(at repositoryURL: URL) throws -> [CheckpointFile] {
        let data = try gitData(["ls-files", "--others", "--exclude-standard", "-z"], at: repositoryURL)
        return try data.split(separator: 0).compactMap { rawPath in
            guard let path = String(data: Data(rawPath), encoding: .utf8), isSafeRelativePath(path) else { return nil }
            let url = repositoryURL.appendingPathComponent(path, isDirectory: false)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return CheckpointFile(path: path, digest: try fileDigest(at: url))
        }.sorted { $0.path < $1.path }
    }

    nonisolated private func workingTreeFingerprint(at repositoryURL: URL) throws -> String {
        let indexPatch = try gitData(["diff", "--cached", "--binary", "--full-index", "HEAD", "--"], at: repositoryURL)
        let worktreePatch = try gitData(["diff", "--binary", "--full-index", "--"], at: repositoryURL)
        let files = try untrackedFiles(at: repositoryURL)
        var hasher = SHA256()
        hasher.update(data: indexPatch)
        hasher.update(data: Data([0]))
        hasher.update(data: worktreePatch)
        for file in files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data(file.digest.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func fileDigest(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func writeUntrackedManifest(_ files: [CheckpointFile], at storageURL: URL) throws {
        let data = try JSONEncoder().encode(files)
        try data.write(to: storageURL.appendingPathComponent("untracked.json"), options: [.atomic])
    }

    nonisolated private func readUntrackedManifest(at storageURL: URL) throws -> [CheckpointFile] {
        let url = storageURL.appendingPathComponent("untracked.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CheckpointFile].self, from: Data(contentsOf: url))
    }

    nonisolated private func removeRelativePath(_ path: String, from repositoryURL: URL) throws {
        guard isSafeRelativePath(path) else { throw CheckpointError.invalidPath(path) }
        let url = repositoryURL.appendingPathComponent(path, isDirectory: false)
        guard url.standardizedFileURL.path.hasPrefix(repositoryURL.standardizedFileURL.path + "/") else {
            throw CheckpointError.invalidPath(path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    nonisolated private func lineStats(oldURL: URL?, newURL: URL?) -> (additions: Int, deletions: Int) {
        let oldLines = oldURL.flatMap { try? String(contentsOf: $0, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0
        let newLines = newURL.flatMap { try? String(contentsOf: $0, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0
        if oldURL == nil { return (newLines, 0) }
        if newURL == nil { return (0, oldLines) }
        return (max(0, newLines - oldLines), max(0, oldLines - newLines))
    }

    nonisolated private func noIndexDiff(oldURL: URL?, newURL: URL?) -> (text: String?, isBinary: Bool) {
        let oldPath = oldURL?.path ?? "/dev/null"
        let newPath = newURL?.path ?? "/dev/null"
        let result = runProcess(
            executable: "/usr/bin/git",
            arguments: ["diff", "--no-index", "--binary", "--full-index", "--", oldPath, newPath],
            directoryURL: nil,
            environment: nil,
            allowedExitCodes: [0, 1]
        )
        guard let result else { return (nil, true) }
        let text = String(data: result.output, encoding: .utf8)
        return (text, text?.contains("Binary files ") == true)
    }

    nonisolated private func gitText(_ arguments: [String], at directoryURL: URL) throws -> String {
        String(data: try gitData(arguments, at: directoryURL), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private func gitData(
        _ arguments: [String],
        at directoryURL: URL,
        environment: [String: String]? = nil
    ) throws -> Data {
        guard let result = runProcess(
            executable: "/usr/bin/git",
            arguments: ["-C", directoryURL.path] + arguments,
            directoryURL: nil,
            environment: environment,
            allowedExitCodes: [0]
        ) else {
            throw CheckpointError.gitUnavailable
        }
        return result.output
    }

    nonisolated private func runGit(
        _ arguments: [String],
        at directoryURL: URL,
        environment: [String: String]? = nil
    ) throws {
        _ = try gitData(arguments, at: directoryURL, environment: environment)
    }

    nonisolated private func runProcess(
        executable: String,
        arguments: [String],
        directoryURL: URL?,
        environment: [String: String]?,
        allowedExitCodes: Set<Int32>
    ) -> ProcessResult? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard allowedExitCodes.contains(process.terminationStatus) else { return nil }
            return ProcessResult(output: outputData, error: errorData)
        } catch {
            return nil
        }
    }
}

private struct AgentRunDiffReport: Sendable {
    let files: [AgentRunFileChange]
    let fingerprint: String
}

private struct CheckpointFile: Codable, Sendable {
    let path: String
    let digest: String
}

private struct ProcessResult: Sendable {
    let output: Data
    let error: Data
}

private enum CheckpointError: LocalizedError {
    case gitUnavailable
    case unavailable(String?)
    case workspaceChanged
    case workspaceChangedAfterRun
    case headChanged
    case incomplete
    case alreadyRestored
    case invalidPath(String)
    case restoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .gitUnavailable: "当前目录不是可用的 Git 项目，无法建立可恢复检查点。"
        case .unavailable(let reason): reason ?? "本次任务没有可用检查点。"
        case .workspaceChanged: "当前会话的项目目录已变化，不能恢复。"
        case .workspaceChangedAfterRun: "任务结束后工作区已有额外修改，已阻止恢复以避免覆盖你的修改。"
        case .headChanged: "Git HEAD 已变化，不能安全恢复到本次任务之前。"
        case .incomplete: "该任务尚未完成，暂不能恢复。"
        case .alreadyRestored: "该任务已经恢复过。"
        case .invalidPath(let path): "检查点包含无效路径：\(path)"
        case .restoreVerificationFailed: "恢复后的工作区校验失败，未标记为已恢复。"
        }
    }
}
