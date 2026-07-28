import Foundation

final class GrokBuildCLIAgentProvider: AgentRunningProvider {
    private struct LaunchConfiguration {
        let arguments: [String]
        let environment: [String: String]
        let logURL: URL
    }

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
            let outputQueue = DispatchQueue(label: "com.chat.ChatMac.grok-output")
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var pendingTools: [String: PendingTool] = [:]
            var lastAssistantText: String?
            var didFinish = false
            var watchdog: DispatchSourceTimer?
            var logOffset: UInt64 = 0
            var logBuffer = Data()
            var lastProgressAt = Date()
            var lastLogStatus: String?
            let launch: LaunchConfiguration

            do {
                launch = try makeLaunchConfiguration(for: request)
                logOffset = Self.fileSize(at: launch.logURL)
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
                    for event in Self.parseEvents(
                        Data(lineData),
                        pendingTools: &pendingTools,
                        lastAssistantText: &lastAssistantText
                    ) {
                        lastProgressAt = Date()
                        continuation.yield(event)
                    }
                }
                if final, !stdoutBuffer.isEmpty {
                    for event in Self.parseEvents(
                        stdoutBuffer,
                        pendingTools: &pendingTools,
                        lastAssistantText: &lastAssistantText
                    ) {
                        lastProgressAt = Date()
                        continuation.yield(event)
                    }
                    stdoutBuffer.removeAll(keepingCapacity: false)
                }
            }

            func finishWithError(_ message: String) {
                guard !didFinish else { return }
                didFinish = true
                watchdog?.cancel()
                watchdog = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.clearRunningProcess(process)
                continuation.finish(throwing: AgentProviderError.processFailed(message))
                self.stop(process)
            }

            func inspectGrokLog() {
                guard let chunk = Self.readLogChunk(from: launch.logURL, offset: &logOffset),
                      !chunk.isEmpty else { return }
                logBuffer.append(chunk)
                while let newlineIndex = logBuffer.firstIndex(of: 0x0A) {
                    let lineData = logBuffer[..<newlineIndex]
                    logBuffer.removeSubrange(...newlineIndex)
                    let data = Data(lineData)
                    if let status = Self.progressStatus(
                        from: data,
                        processID: process.processIdentifier
                    ) {
                        lastProgressAt = Date()
                        if status != lastLogStatus {
                            lastLogStatus = status
                            continuation.yield(.status(status))
                        }
                    }
                    if let message = Self.terminalFailureMessage(
                        from: data,
                        processID: process.processIdentifier
                    ) {
                        finishWithError(message)
                        return
                    }
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
                    watchdog?.cancel()
                    watchdog = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOutput = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOutput.isEmpty { stdoutBuffer.append(remainingOutput) }
                    let remainingError = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingError.isEmpty { stderrBuffer.append(remainingError) }
                    consumeLines(final: true)

                    self?.clearRunningProcess(process)
                    if process.terminationStatus == 0 {
                        continuation.finish()
                    } else if process.terminationStatus == 127 {
                        continuation.finish(throwing: AgentProviderError.grokUnavailable)
                    } else {
                        continuation.finish(
                            throwing: AgentProviderError.processFailed(
                                Self.readableProcessError(from: stderrBuffer)
                            )
                        )
                    }
                }
            }

            do {
                setRunningProcess(process)
                try process.run()
                continuation.yield(.status("Grok Build Agent 已启动"))

                let timer = DispatchSource.makeTimerSource(queue: outputQueue)
                timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(500))
                timer.setEventHandler {
                    guard !didFinish else { return }
                    inspectGrokLog()
                    guard !didFinish,
                          Date().timeIntervalSince(lastProgressAt) >= 180 else { return }
                    finishWithError("Grok Build 超时：连续 180 秒没有收到新的运行进展。")
                }
                watchdog = timer
                timer.resume()
            } catch {
                clearRunningProcess(process)
                continuation.finish(throwing: AgentProviderError.processFailed(error.localizedDescription))
            }

            continuation.onTermination = { [weak self, weak process] _ in
                guard let self, let process else { return }
                outputQueue.async {
                    watchdog?.cancel()
                    watchdog = nil
                }
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
        if runningProcess === process { runningProcess = nil }
        stateLock.unlock()
    }

    nonisolated private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            if process.isRunning { process.terminate() }
        }
    }

    private func makeLaunchConfiguration(
        for request: AgentRunRequest
    ) throws -> LaunchConfiguration {
        guard request.target.engine == .grokBuildCLI,
              request.target.engine.supportedAPIs.contains(request.target.apiKind),
              let modelIdentifier = request.target.modelIdentifier,
              let baseURLString = request.target.baseURLString,
              let keychainAccount = request.target.keychainAccount else {
            throw AgentProviderError.incompatibleConfiguration
        }
        guard let apiKey = try keychain.read(account: keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
            throw AgentProviderError.missingAPIKey(request.target.title)
        }

        let baseURL = try normalizedBaseURL(baseURLString, apiKind: request.target.apiKind)
        let runtimeURL = try prepareRuntime(
            modelIdentifier: modelIdentifier,
            displayName: request.target.title,
            baseURL: baseURL,
            apiKind: request.target.apiKind,
            additionalWritableURLs: request.additionalWritableURLs
        )

        var grokArguments = [
            "--cwd", request.workspaceURL.path,
            "--sandbox", request.additionalWritableURLs.isEmpty ? "workspace" : "chatmac",
            "--permission-mode", "acceptEdits",
            "--output-format", "streaming-json",
            "--model", modelIdentifier,
        ]
        if let effort = request.reasoningEffort.commandValue {
            grokArguments += ["--reasoning-effort", effort]
        }
        if let threadID = request.threadID {
            grokArguments += ["--resume", threadID]
        }
        grokArguments += ["-p", request.effectivePrompt]

        var environment = ProcessInfo.processInfo.environment
        environment["CHATMAC_GROK_API_KEY"] = apiKey
        environment["CHATMAC_GROK_HOME"] = runtimeURL.path
        let shellCommand = "GROK_EXEC=\"$HOME/.grok/bin/grok\"; if [ ! -x \"$GROK_EXEC\" ]; then GROK_EXEC=\"$(command -v grok)\"; fi; [ -n \"$GROK_EXEC\" ] || exit 127; exec env GROK_HOME=\"$CHATMAC_GROK_HOME\" XAI_API_KEY=\"$CHATMAC_GROK_API_KEY\" \"$GROK_EXEC\" \"$@\""
        return LaunchConfiguration(
            arguments: ["-lic", shellCommand, "ChatMacGrok"] + grokArguments,
            environment: environment,
            logURL: runtimeURL
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("unified.jsonl")
        )
    }

    private func prepareRuntime(
        modelIdentifier: String,
        displayName: String,
        baseURL: String,
        apiKind: AgentAPIKind,
        additionalWritableURLs: [URL]
    ) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let runtimeURL = applicationSupport
            .appendingPathComponent("ChatMac", isDirectory: true)
            .appendingPathComponent("GrokRuntime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true
        )

        let backend = apiKind == .chatCompletions ? "chat_completions" : "responses"
        let escapedID = escapeTOML(modelIdentifier)
        let config = """
        [endpoints]
        models_base_url = "\(escapeTOML(baseURL))"

        [models]
        default = "\(escapedID)"

        [model."\(escapedID)"]
        model = "\(escapedID)"
        name = "\(escapeTOML(displayName))"
        base_url = "\(escapeTOML(baseURL))"
        api_backend = "\(backend)"
        env_key = "CHATMAC_GROK_API_KEY"
        """
        try Data(config.utf8).write(
            to: runtimeURL.appendingPathComponent("config.toml"),
            options: .atomic
        )

        if !additionalWritableURLs.isEmpty {
            let paths = additionalWritableURLs
                .map { "\"\(escapeTOML($0.standardizedFileURL.path))\"" }
                .joined(separator: ", ")
            let sandbox = """
            [profiles.chatmac]
            extends = "workspace"
            read_write = [\(paths)]
            """
            try Data(sandbox.utf8).write(
                to: runtimeURL.appendingPathComponent("sandbox.toml"),
                options: .atomic
            )
        }
        return runtimeURL
    }

    private func normalizedBaseURL(_ rawValue: String, apiKind: AgentAPIKind) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw AgentProviderError.invalidBaseURL(rawValue)
        }
        let suffix = apiKind == .chatCompletions ? "/chat/completions" : "/responses"
        if components.path.hasSuffix(suffix) {
            components.path.removeLast(suffix.count)
        }
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
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private static func readLogChunk(from url: URL, offset: inout UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let currentSize = fileSize(at: url)
        if currentSize < offset { offset = 0 }
        guard currentSize > offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return data
        } catch {
            return nil
        }
    }

    private static func progressStatus(from data: Data, processID: Int32) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == processID,
              let event = object["msg"] as? String else { return nil }
        switch event {
        case "model catalog: fetching":
            return "Grok Build 正在读取模型配置"
        case "agent initialized":
            return "Grok Build 正在初始化工作区"
        case "prompt received", "shell.handle_prompt.start":
            return "Grok Build 已接收任务"
        case "shell.turn.inference_start":
            return "模型正在分析任务"
        default:
            return nil
        }
    }

    private static func terminalFailureMessage(from data: Data, processID: Int32) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? NSNumber)?.int32Value == processID,
              let event = object["msg"] as? String,
              event == "shell.turn.inference_failed" || event == "turn.terminal_failure" else {
            return nil
        }
        let context = object["ctx"] as? [String: Any]
        let rawMessage = (context?["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawMessage, !rawMessage.isEmpty else {
            return "Grok Build 任务失败，CLI 没有返回可用的错误信息。"
        }
        if rawMessage.contains("missing field `output`") {
            return "Grok Build 无法解析中转站的 Responses 返回：缺少 output 字段。该端点虽然接受 /v1/responses，但返回事件与 Grok Build CLI 不兼容。"
        }
        return "Grok Build 任务失败：\(rawMessage)"
    }

    private static func parseEvents(
        _ data: Data,
        pendingTools: inout [String: PendingTool],
        lastAssistantText: inout String?
    ) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "system", "session_start", "thread.started":
            let sessionID = object["sessionId"] as? String
                ?? object["session_id"] as? String
                ?? object["thread_id"] as? String
            var events: [AgentEvent] = []
            if let sessionID, !sessionID.isEmpty { events.append(.threadStarted(sessionID)) }
            events.append(.status("Grok Build 正在分析任务"))
            return events

        case "assistant", "agent_message", "message":
            let text = assistantText(from: object)
            guard !text.isEmpty, text != lastAssistantText else { return [] }
            lastAssistantText = text
            return [.assistant(text)]

        case "tool_use", "tool_call":
            let id = object["toolUseId"] as? String
                ?? object["tool_use_id"] as? String
                ?? object["id"] as? String
            guard let id else { return [] }
            let name = object["toolName"] as? String
                ?? object["name"] as? String
                ?? "Tool"
            let input = object["toolInput"] as? [String: Any]
                ?? object["input"] as? [String: Any]
                ?? [:]
            pendingTools[id] = PendingTool(name: name, summary: toolSummary(name: name, input: input))
            return [.status("正在执行 \(name)")]

        case "user", "tool_result":
            return toolResultEvents(from: object, pendingTools: &pendingTools)

        case "result", "session_end", "turn_completed":
            var events: [AgentEvent] = []
            let text = object["text"] as? String ?? object["result"] as? String ?? ""
            if !text.isEmpty, text != lastAssistantText {
                lastAssistantText = text
                events.append(.assistant(text))
            }
            let usage = object["usage"] as? [String: Any]
            events.append(.completed(AgentUsage(
                inputTokens: usage?["input_tokens"] as? Int ?? usage?["inputTokens"] as? Int,
                outputTokens: usage?["output_tokens"] as? Int ?? usage?["outputTokens"] as? Int
            )))
            return events

        case "error":
            return [.warning(object["message"] as? String ?? "Grok Build 任务失败。")]

        default:
            return []
        }
    }

    private static func assistantText(from object: [String: Any]) -> String {
        if let text = object["text"] as? String { return text }
        guard let message = object["message"] as? [String: Any] else { return "" }
        if let text = message["text"] as? String { return text }
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private static func toolResultEvents(
        from object: [String: Any],
        pendingTools: inout [String: PendingTool]
    ) -> [AgentEvent] {
        let blocks: [[String: Any]]
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            blocks = content
        } else {
            blocks = [object]
        }
        return blocks.compactMap { block in
            let id = block["toolUseId"] as? String
                ?? block["tool_use_id"] as? String
            guard let id, let tool = pendingTools.removeValue(forKey: id) else { return nil }
            let output = contentText(block["toolResult"] ?? block["content"] ?? block["output"])
            let isError = block["isError"] as? Bool ?? block["is_error"] as? Bool ?? false
            if ["run_terminal_cmd", "Bash"].contains(tool.name) {
                return .command(command: tool.summary, output: output, exitCode: isError ? 1 : 0)
            }
            if ["search_replace", "write_file", "Edit", "Write"].contains(tool.name) {
                return .fileChange(tool.summary)
            }
            return isError ? .warning(output) : .status("\(tool.name) 已完成")
        }
    }

    private static func toolSummary(name: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String, !command.isEmpty { return command }
        if let path = input["file_path"] as? String, !path.isEmpty { return "\(name): \(path)" }
        if let path = input["path"] as? String, !path.isEmpty { return "\(name): \(path)" }
        return name
    }

    private static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func readableProcessError(from data: Data) -> String {
        guard let rawText = String(data: data, encoding: .utf8) else { return "" }
        let text = stripANSI(rawText)
        let lines = text.split(separator: "\n").map(String.init)
        let meaningful = lines.filter { !$0.contains(" WARN ") }
        return (meaningful.isEmpty ? lines : meaningful).suffix(10).joined(separator: "\n")
    }

    private static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\u{001B}\\[[0-?]*[ -/]*[@-~]") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
