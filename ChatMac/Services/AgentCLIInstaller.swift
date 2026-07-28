import Foundation

struct AgentCLIInstallationResult: Sendable {
    let exitCode: Int32
    let output: String

    var succeeded: Bool { exitCode == 0 }
}

enum AgentCLIInstaller {
    nonisolated static func command(for engine: AgentEngineKind) -> String? {
        switch engine {
        case .claudeCodeCLI:
            "bash -c 'tmp=$(mktemp) && curl -fsSL https://claude.ai/install.sh -o $tmp && bash $tmp; status=$?; rm -f $tmp; exit $status' || npm i -g @anthropic-ai/claude-code@latest"
        case .codexCLI:
            "npm i -g @openai/codex@latest"
        case .grokBuildCLI, .disabled:
            nil
        }
    }

    nonisolated static func install(_ engine: AgentEngineKind) -> AgentCLIInstallationResult {
        guard let command = command(for: engine) else {
            return AgentCLIInstallationResult(exitCode: 64, output: "该 Agent CLI 不支持自动安装。")
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return AgentCLIInstallationResult(exitCode: 1, output: error.localizedDescription)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgentCLIInstallationResult(
            exitCode: process.terminationStatus,
            output: String(output.suffix(12_000))
        )
    }
}
