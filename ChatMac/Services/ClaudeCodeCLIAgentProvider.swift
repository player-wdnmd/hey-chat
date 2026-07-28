import Foundation

final class ClaudeCodeCLIAgentProvider: AgentRunningProvider {
    private struct PendingTool {
        let name: String
        let summary: String
    }

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
            let outputQueue = DispatchQueue(label: "com.chat.ChatMac.claude-output")
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var pendingTools: [String: PendingTool] = [:]
            var didFinish = false

            do {
                let launch = try makeLaunchConfiguration(for: request)
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = launch.arguments
                process.environment = launch.environment
                process.currentDirectoryURL = request.workspaceURL
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
            } catch {
                continuation.finish(throwing: error)
                return
            }

            func consumeLines(final: Bool = false) {
                while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                    let lineData = stdoutBuffer[..<newlineIndex]
                    stdoutBuffer.removeSubrange(...newlineIndex)
                    guard !lineData.isEmpty else { continue }
                    for event in Self.parseEvents(Data(lineData), pendingTools: &pendingTools) {
                        continuation.yield(event)
                    }
                }

                if final, !stdoutBuffer.isEmpty {
                    for event in Self.parseEvents(stdoutBuffer, pendingTools: &pendingTools) {
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
                        if errorText.localizedCaseInsensitiveContains("claude: command not found") {
                            continuation.finish(throwing: AgentProviderError.claudeUnavailable)
                        } else {
                            continuation.finish(throwing: AgentProviderError.processFailed(errorText))
                        }
                    }
                }
            }

            do {
                setRunningProcess(process)
                try process.run()
                continuation.yield(.status("Claude Code Agent 已启动"))
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
        guard request.target.engine == .claudeCodeCLI,
              request.target.apiKind == .anthropicMessages else {
            throw AgentProviderError.incompatibleConfiguration
        }

        var claudeArguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "acceptEdits",
        ]
        for url in request.additionalWritableURLs {
            claudeArguments += ["--add-dir", url.path]
        }
        if let modelIdentifier = request.target.modelIdentifier,
           !modelIdentifier.isEmpty {
            claudeArguments += ["--model", modelIdentifier]
        }
        if let effort = request.reasoningEffort.commandValue {
            claudeArguments += ["--effort", effort]
        }
        if let threadID = request.threadID {
            claudeArguments += ["--resume", threadID]
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

        let runtimeURL = try prepareRuntimeDirectory(named: "ClaudeRuntime")
        var environment = ProcessInfo.processInfo.environment
        environment["CHATMAC_CLAUDE_BASE_URL"] = try normalizedAnthropicBaseURL(baseURLString)
        environment["CHATMAC_CLAUDE_API_KEY"] = apiKey
        environment["CHATMAC_CLAUDE_CONFIG_DIR"] = runtimeURL.path
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        let shellCommand = "exec env -u ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR=\"$CHATMAC_CLAUDE_CONFIG_DIR\" ANTHROPIC_BASE_URL=\"$CHATMAC_CLAUDE_BASE_URL\" ANTHROPIC_API_KEY=\"$CHATMAC_CLAUDE_API_KEY\" claude \"$@\""

        claudeArguments.append(request.effectivePrompt)
        return (
            arguments: ["-lic", shellCommand, "ChatMacClaude"] + claudeArguments,
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

    private func normalizedAnthropicBaseURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw AgentProviderError.invalidBaseURL(rawValue)
        }
        for suffix in ["/v1/messages", "/v1"] where components.path.hasSuffix(suffix) {
            components.path.removeLast(suffix.count)
            break
        }
        components.query = nil
        components.fragment = nil
        guard let normalized = components.url?.absoluteString else {
            throw AgentProviderError.invalidBaseURL(rawValue)
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    private static func parseEvents(
        _ data: Data,
        pendingTools: inout [String: PendingTool]
    ) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
                return [.threadStarted(sessionID), .status("Claude Code 正在分析任务")]
            }
            return [.status("Claude Code 正在分析任务")]

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [AgentEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.assistant(text))
                    }
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let summary = toolSummary(name: name, input: input)
                    pendingTools[id] = PendingTool(name: name, summary: summary)
                    if let progress = planProgress(name: name, input: input) {
                        events.append(progress)
                    }
                    events.append(.status("正在执行 \(name)"))
                default:
                    continue
                }
            }
            return events

        case "user":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String,
                      let tool = pendingTools.removeValue(forKey: id) else { return nil }
                let output = contentText(block["content"])
                let isError = block["is_error"] as? Bool ?? false
                if tool.name == "Bash" {
                    return .command(command: tool.summary, output: output, exitCode: isError ? 1 : 0)
                }
                if ["Edit", "Write", "NotebookEdit"].contains(tool.name) {
                    return .fileChange(tool.summary)
                }
                if isError {
                    return .warning(output.isEmpty ? "\(tool.name) 执行失败" : output)
                }
                return .status("\(tool.name) 已完成")
            }

        case "result":
            if object["is_error"] as? Bool == true {
                let message = object["result"] as? String ?? "Claude Code 任务失败。"
                return [.warning(message)]
            }
            let usage = object["usage"] as? [String: Any]
            return [.completed(AgentUsage(
                inputTokens: usage?["input_tokens"] as? Int,
                outputTokens: usage?["output_tokens"] as? Int
            ))]

        default:
            return []
        }
    }

    private static func toolSummary(name: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String, !command.isEmpty { return command }
        if let path = input["file_path"] as? String, !path.isEmpty { return "\(name): \(path)" }
        if let path = input["path"] as? String, !path.isEmpty { return "\(name): \(path)" }
        return name
    }

    private static func planProgress(
        name: String,
        input: [String: Any]
    ) -> AgentEvent? {
        guard ["TodoWrite", "UpdatePlan"].contains(name),
              let items = input["todos"] as? [[String: Any]]
                ?? input["plan"] as? [[String: Any]],
              !items.isEmpty else { return nil }
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

    private static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func readableProcessError(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n")
            .map(String.init)
            .suffix(10)
            .joined(separator: "\n")
    }
}
