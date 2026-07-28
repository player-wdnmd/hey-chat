import Foundation

final class CodexCLIAgentProvider: AgentRunningProvider {
    private static let compactPrompt = "压缩上下文时保留用户目标与硬性约束、当前计划和完成状态、精确文件路径与符号、已执行命令及非零退出原因、未解决问题和最近请求；省略成功命令的长输出和重复过程；不要虚构已验证结果；用简洁结构化条目输出，确保下一轮可以直接继续。"
    private let keychain = KeychainService()
    private let stateLock = NSLock()
    private var runningProcess: Process?

    func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            guard request.workspaceURL.hasDirectoryPath,
                  FileManager.default.fileExists(atPath: request.workspaceURL.path) else {
                continuation.finish(throwing: AgentProviderError.invalidWorkspace)
                return
            }

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            let outputQueue = DispatchQueue(label: "com.chat.ChatMac.codex-output")
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var didFinish = false

            do {
                let launch = try makeLaunchConfiguration(for: request)
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = launch.arguments
                process.environment = launch.environment
                process.currentDirectoryURL = request.workspaceURL
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe
            } catch {
                continuation.finish(throwing: error)
                return
            }

            func consumeLines(final: Bool = false) {
                while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                    let lineData = stdoutBuffer[..<newlineIndex]
                    stdoutBuffer.removeSubrange(...newlineIndex)
                    guard !lineData.isEmpty else { continue }
                    if let event = Self.parseEvent(Data(lineData)) {
                        continuation.yield(event)
                    }
                }

                if final, !stdoutBuffer.isEmpty {
                    if let event = Self.parseEvent(stdoutBuffer) {
                        continuation.yield(event)
                    }
                    stdoutBuffer.removeAll(keepingCapacity: false)
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                outputQueue.async {
                    guard !data.isEmpty else { return }
                    stdoutBuffer.append(data)
                    consumeLines()
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                outputQueue.async {
                    guard !data.isEmpty else { return }
                    stderrBuffer.append(data)
                    if stderrBuffer.count > 64_000 {
                        stderrBuffer.removeFirst(stderrBuffer.count - 64_000)
                    }
                }
            }

            process.terminationHandler = { [weak self] process in
                outputQueue.async {
                    guard !didFinish else { return }
                    didFinish = true
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOutput = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOutput.isEmpty {
                        stdoutBuffer.append(remainingOutput)
                    }
                    let remainingError = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingError.isEmpty {
                        stderrBuffer.append(remainingError)
                    }
                    consumeLines(final: true)

                    self?.clearRunningProcess(process)
                    if process.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        let errorText = Self.readableProcessError(from: stderrBuffer)
                        if errorText.localizedCaseInsensitiveContains("codex: command not found") {
                            continuation.finish(throwing: AgentProviderError.codexUnavailable)
                        } else {
                            continuation.finish(
                                throwing: AgentProviderError.processFailed(errorText)
                            )
                        }
                    }
                }
            }

            do {
                setRunningProcess(process)
                try process.run()
                continuation.yield(.status("Codex Agent 已启动"))
                let promptData = Data((request.effectivePrompt + "\n").utf8)
                try stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                clearRunningProcess(process)
                continuation.finish(throwing: AgentProviderError.processFailed(error.localizedDescription))
            }

            continuation.onTermination = { [weak self, weak process] _ in
                guard let self, let process else { return }
                self.stop(process)
            }
        }
    }

    func cancel() {
        stateLock.lock()
        let process = runningProcess
        stateLock.unlock()
        guard let process else { return }
        stop(process)
    }

    private func setRunningProcess(_ process: Process) {
        stateLock.lock()
        runningProcess = process
        stateLock.unlock()
    }

    private func clearRunningProcess(_ process: Process) {
        stateLock.lock()
        if runningProcess === process {
            runningProcess = nil
        }
        stateLock.unlock()
    }

    nonisolated private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func makeLaunchConfiguration(
        for request: AgentRunRequest
    ) throws -> (arguments: [String], environment: [String: String]) {
        var codexArguments = [
            "--disable", "plugins",
            "--disable", "remote_plugin",
            "--disable", "apps",
            "--ask-for-approval", "never",
            "--sandbox", "workspace-write",
            "--cd", request.workspaceURL.path,
        ]
        for url in request.additionalWritableURLs {
            codexArguments += ["--add-dir", url.path]
        }
        var environment = ProcessInfo.processInfo.environment

        guard request.target.engine == .codexCLI,
              request.target.apiKind == .responses else {
            throw AgentProviderError.incompatibleConfiguration
        }

        guard let keychainAccount = request.target.keychainAccount,
              let baseURLString = request.target.baseURLString else {
            throw AgentProviderError.incompatibleConfiguration
        }
        guard let apiKey = try keychain.read(account: keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
            throw AgentProviderError.missingAPIKey(request.target.title)
        }
        let baseURL = try normalizedResponsesBaseURL(baseURLString)
        let runtimeURL = try prepareRuntimeDirectory(named: "CodexRuntime")
        environment["CHATMAC_AGENT_API_KEY"] = apiKey
        environment["CHATMAC_CODEX_HOME"] = runtimeURL.path
        let providerConfig = [
            "name=\"hey chat API\"",
            "base_url=\"\(escapeTOML(baseURL))\"",
            "env_key=\"CHATMAC_AGENT_API_KEY\"",
            "wire_api=\"responses\"",
        ].joined(separator: ",")
        codexArguments += [
            "-c", "model_provider=\"chatmac\"",
            "-c", "model_providers.chatmac={\(providerConfig)}",
            "-c", "compact_prompt=\"\(escapeTOML(Self.compactPrompt))\"",
        ]
        if let effort = request.reasoningEffort.commandValue {
            codexArguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }

        if let modelIdentifier = request.target.modelIdentifier,
           !modelIdentifier.isEmpty {
            codexArguments += ["-m", modelIdentifier]
        }

        let imageArguments = request.imageAttachments.flatMap { ["--image", $0.path] }
        if let threadID = request.threadID {
            codexArguments += ["exec", "resume", "--json"]
                + imageArguments
                + [threadID, "-"]
        } else {
            codexArguments += ["exec", "--json"] + imageArguments + ["-"]
        }

        return (
            arguments: [
                "-lic",
                "exec env CODEX_HOME=\"$CHATMAC_CODEX_HOME\" codex \"$@\"",
                "ChatMacCodex",
            ] + codexArguments,
            environment: environment
        )
    }

    private func prepareRuntimeDirectory(named name: String) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let runtimeURL = applicationSupport
            .appendingPathComponent("ChatMac", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true
        )
        return runtimeURL
    }

    private func normalizedResponsesBaseURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw AgentProviderError.invalidBaseURL(rawValue)
        }

        var path = components.path
        for suffix in ["/chat/completions", "/responses"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components.path = path.isEmpty ? "/v1" : path
        components.query = nil
        components.fragment = nil
        guard let normalized = components.url?.absoluteString else {
            throw AgentProviderError.invalidBaseURL(rawValue)
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    private func escapeTOML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseEvent(_ data: Data) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }

        switch type {
        case "thread.started":
            guard let threadID = object["thread_id"] as? String else { return nil }
            return .threadStarted(threadID)

        case "turn.started":
            return .status("模型正在分析任务")

        case "item.started", "item.updated":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  ["todo_list", "plan"].contains(itemType) else { return nil }
            return planProgress(item)

        case "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return nil }
            switch itemType {
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return nil }
                return .assistant(text)
            case "command_execution":
                let command = item["command"] as? String ?? "终端命令"
                let output = item["aggregated_output"] as? String ?? ""
                let exitCode = item["exit_code"] as? Int
                return .command(command: command, output: output, exitCode: exitCode)
            case "file_change":
                return .fileChange(fileChangeSummary(item))
            case "todo_list", "plan":
                return planProgress(item)
            case "error":
                guard let message = item["message"] as? String else { return nil }
                return .warning(message)
            default:
                return nil
            }

        case "error":
            guard let message = object["message"] as? String else { return nil }
            if message.hasPrefix("Reconnecting...") {
                return .status(message)
            }
            return .warning(message)

        case "turn.completed":
            let usage = object["usage"] as? [String: Any]
            return .completed(
                AgentUsage(
                    inputTokens: usage?["input_tokens"] as? Int,
                    outputTokens: usage?["output_tokens"] as? Int
                )
            )

        case "turn.failed":
            let error = object["error"] as? [String: Any]
            return .warning(error?["message"] as? String ?? "Agent 任务失败。")

        default:
            return nil
        }
    }

    private static func fileChangeSummary(_ item: [String: Any]) -> String {
        guard let changes = item["changes"] as? [[String: Any]], !changes.isEmpty else {
            return "文件已更新"
        }
        return changes.compactMap { change in
            guard let path = change["path"] as? String else { return nil }
            let kind = change["kind"] as? String ?? "update"
            return "\(kind): \(path)"
        }.joined(separator: "\n")
    }

    private static func planProgress(_ item: [String: Any]) -> AgentEvent? {
        let items = item["items"] as? [[String: Any]]
            ?? item["plan"] as? [[String: Any]]
        guard let items, !items.isEmpty else { return nil }
        let inProgressIndex = items.firstIndex {
            ($0["status"] as? String) == "in_progress"
        }
        let completedCount = items.filter {
            ($0["status"] as? String) == "completed"
        }.count
        let currentStep = inProgressIndex.map { $0 + 1 }
            ?? min(items.count, max(1, completedCount))
        return .planProgress(currentStep: currentStep, totalSteps: items.count)
    }

    private static func readableProcessError(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let meaningfulLines = text
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                !line.contains(" WARN ") && !line.contains(" INFO ")
            }
        return meaningfulLines.suffix(8).joined(separator: "\n")
    }
}
