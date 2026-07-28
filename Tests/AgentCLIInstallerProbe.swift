import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AgentCLIInstallerProbe failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private struct AgentCLIInstallerProbe {
    static func main() {
        require(
            AgentCLIInstaller.command(for: .codexCLI) == "npm i -g @openai/codex@latest",
            "Codex 安装命令不一致"
        )
        require(
            AgentCLIInstaller.command(for: .claudeCodeCLI) == "bash -c 'tmp=$(mktemp) && curl -fsSL https://claude.ai/install.sh -o $tmp && bash $tmp; status=$?; rm -f $tmp; exit $status' || npm i -g @anthropic-ai/claude-code@latest",
            "Claude Code 安装命令不一致"
        )
        require(AgentCLIInstaller.command(for: .grokBuildCLI) == nil, "Grok 不应显示自动安装")
        require(AgentCLIInstaller.command(for: .disabled) == nil, "停用状态不应显示自动安装")

        let unsupported = AgentCLIInstaller.install(.disabled)
        require(!unsupported.succeeded && unsupported.exitCode == 64, "不支持的引擎必须直接失败")
        print("AgentCLIInstallerProbe passed")
    }
}
