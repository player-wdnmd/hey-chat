import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AgentWorkspaceView: View {
    let models: [AIModelConfiguration]
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @State private var isAttachmentDropTarget = false

    private var targets: [AgentProviderTarget] {
        configuredTargets
    }

    private var configuredTargets: [AgentProviderTarget] {
        models.compactMap(AgentProviderTarget.configuredModel).sorted {
            if $0.channelName != $1.channelName {
                return $0.channelName.localizedStandardCompare($1.channelName) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var configuredChannels: [String] {
        Array(Set(configuredTargets.map(\.channelName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var selectedTarget: AgentProviderTarget? {
        targets.first { $0.id == viewModel.selectedTargetID }
    }

    private var selectedReasoningEffort: AgentReasoningEffort {
        selectedTarget.map { viewModel.reasoningEffort(for: $0) } ?? .automatic
    }

    private var shouldDeferReturnToTextInput: Bool {
        guard let textInputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient else {
            return true
        }
        return textInputClient.hasMarkedText()
    }

    private var transcriptTurns: [AgentTranscriptTurn] {
        AgentTranscriptTurn.grouping(viewModel.entries)
    }

    private var hasSendableContent: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.draftAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.42)

            if viewModel.workspaceURL == nil {
                workspaceEmptyState
            } else {
                transcript
                composer
            }
        }
        .task {
            viewModel.restoreWorkspace()
            viewModel.reconcileTargetIDs(targets.map(\.id))
            viewModel.refreshCLIStatuses()
        }
        .onChange(of: targets.map(\.id)) { _, ids in
            viewModel.reconcileTargetIDs(ids)
        }
        .alert(
            "CLI 安装失败",
            isPresented: Binding(
                get: { viewModel.cliInstallationError != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissCLIInstallationError() }
                }
            )
        ) {
            Button("好", role: .cancel) {
                viewModel.dismissCLIInstallationError()
            }
        } message: {
            Text(viewModel.cliInstallationError ?? "安装命令执行失败。")
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("hey chat")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(viewModel.selectedSessionTitle)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            if let selectedTarget {
                Button {
                    viewModel.performCLIAction(for: selectedTarget.engine)
                } label: {
                    Label(
                        viewModel.cliActionStatus(for: selectedTarget.engine).text,
                        systemImage: viewModel.cliActionStatus(for: selectedTarget.engine).icon
                    )
                    .lineLimit(1)
                }
                .buttonStyle(AeroHeaderButtonStyle())
                .disabled(viewModel.installingCLI != nil || viewModel.isRunning)
                .help(viewModel.cliActionHelp(for: selectedTarget.engine))
            }

            Menu {
                if configuredTargets.isEmpty {
                    Text("请先在模型管理中启用 Agent")
                } else {
                    ForEach(configuredChannels, id: \.self) { channel in
                        Section(channel) {
                            ForEach(configuredTargets.filter { $0.channelName == channel }) { target in
                                targetButton(target)
                            }
                        }
                    }
                }
            } label: {
                Label(selectedTarget?.title ?? "配置 Agent 模型", systemImage: "cpu")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning)
            .help("选择 Agent 模型与渠道")

            if let selectedTarget {
                Menu {
                    Button {
                        viewModel.resetReasoningEffort(for: selectedTarget)
                    } label: {
                        HStack {
                            Text("模型默认（\(selectedTarget.defaultReasoningEffort.displayName)）")
                            if !viewModel.hasReasoningEffortOverride(for: selectedTarget) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(
                        selectedTarget.engine.supportedReasoningEfforts.filter { $0 != .automatic },
                        id: \.self
                    ) { effort in
                        Button {
                            viewModel.selectReasoningEffort(effort, for: selectedTarget)
                        } label: {
                            HStack {
                                Text(effort.displayName)
                                if viewModel.hasReasoningEffortOverride(for: selectedTarget),
                                   selectedReasoningEffort == effort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(selectedReasoningEffort.displayName, systemImage: "brain.head.profile")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .buttonStyle(AeroHeaderButtonStyle())
                .disabled(viewModel.isRunning)
                .help("调整本次 Agent 会话的推理强度")
            }

            Menu {
                Button {
                    chooseAdditionalDirectory()
                } label: {
                    Label("添加授权目录", systemImage: "folder.badge.plus")
                }

                if !viewModel.additionalWritableURLs.isEmpty {
                    Divider()
                    ForEach(viewModel.additionalWritableURLs, id: \.path) { url in
                        Button(role: .destructive) {
                            viewModel.removeWritableDirectory(url)
                        } label: {
                            Label("移除 \(url.lastPathComponent)", systemImage: "minus.circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    if !viewModel.additionalWritableURLs.isEmpty {
                        Text("\(viewModel.additionalWritableURLs.count)")
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.workspaceURL == nil)
            .help("管理额外可写目录")

            Button(action: chooseWorkspace) {
                Label(viewModel.workspaceURL?.lastPathComponent ?? "选择项目", systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning)
            .help("选择本机项目目录")

            Button {
                viewModel.startNewSession()
            } label: {
                Image(systemName: "plus.bubble")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.workspaceURL == nil)
            .help("新建 Agent 会话")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 19)
        .background {
            LinearGradient(
                colors: [AeroTheme.sky, AeroTheme.deepSky, AeroTheme.leaf],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func targetButton(_ target: AgentProviderTarget) -> some View {
        Button {
            viewModel.selectTarget(target)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(target.title)
                    Text(target.subtitle)
                }
                if viewModel.selectedTargetID == target.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var workspaceEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(AeroTheme.deepSky)
            Text("选择开发项目")
                .font(.system(size: 25, weight: .heavy))
                .foregroundStyle(AeroTheme.text)
            Button(action: chooseWorkspace) {
                Label("打开项目目录", systemImage: "folder")
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 30) {
                    if viewModel.entries.isEmpty {
                        VStack(spacing: 8) {
                            Text(viewModel.workspaceURL?.lastPathComponent ?? "Project")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundStyle(AeroTheme.text)
                            Text("Ready")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AeroTheme.deepLeaf)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    } else {
                        ForEach(transcriptTurns) { turn in
                            AgentTurnView(
                                turn: turn,
                                isActive: viewModel.isRunning && turn.id == transcriptTurns.last?.id,
                                liveProgress: viewModel.isRunning && turn.id == transcriptTurns.last?.id
                                    ? viewModel.runProgress
                                    : nil
                            )
                            .id(turn.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("agent-transcript-bottom")
                    }
                }
                .frame(maxWidth: 960)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.entries.last?.id) { _, id in
                guard id != nil else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("agent-transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            HStack {
                Label(viewModel.statusText, systemImage: viewModel.isRunning ? "gearshape.2" : "checkmark.circle")
                Spacer()
                Text(viewModel.threadID == nil ? viewModel.selectedSessionTitle : "会话已连接")
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AeroTheme.faintText)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if !viewModel.draftAttachments.isEmpty {
                        attachmentStrip
                    }

                    TextEditor(text: $viewModel.draft)
                        .font(.system(size: 14.5))
                        .foregroundStyle(AeroTheme.text)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 58, maxHeight: 92)
                        .onKeyPress(keys: [.return], phases: [.down]) { keyPress in
                            if keyPress.modifiers.contains(.shift) || shouldDeferReturnToTextInput {
                                return .ignored
                            }
                            guard selectedTarget != nil,
                                  !viewModel.isRunning,
                                  hasSendableContent else {
                                return .handled
                            }
                            sendDraft()
                            return .handled
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.68))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    isAttachmentDropTarget
                                        ? AeroTheme.deepLeaf.opacity(0.8)
                                        : AeroTheme.deepSky.opacity(0.2),
                                    lineWidth: isAttachmentDropTarget ? 2 : 1
                                )
                        }
                }

                VStack(spacing: 8) {
                    attachmentButton

                    if viewModel.isRunning {
                        Button(action: viewModel.cancel) {
                            Image(systemName: "stop.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroPrimaryButtonStyle())
                        .help("停止 Agent")
                    } else {
                        Button(action: sendDraft) {
                            Image(systemName: "arrow.up")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroPrimaryButtonStyle())
                        .disabled(selectedTarget == nil || !hasSendableContent)
                        .help("发送任务")
                    }
                }
            }
            .padding(14)
            .aeroGlass(cornerRadius: 18)
            .dropDestination(for: URL.self) { urls, _ in
                guard !viewModel.isRunning else { return false }
                viewModel.addAttachments(urls)
                return !urls.isEmpty
            } isTargeted: { isTargeted in
                isAttachmentDropTarget = isTargeted
            }
        }
        .frame(maxWidth: 960)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.2))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(viewModel.draftAttachments) { attachment in
                    AgentAttachmentChip(attachment: attachment) {
                        viewModel.removeAttachment(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
    }

    private var attachmentButton: some View {
        Button(action: chooseAttachments) {
            Image(systemName: "plus")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(AeroPrimaryButtonStyle())
        .disabled(viewModel.isRunning)
        .help("添加附件")
        .contextMenu {
            if !viewModel.draftAttachments.isEmpty {
                Button("清除全部附件", systemImage: "xmark.circle", role: .destructive) {
                    viewModel.clearAttachments()
                }
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 工作目录"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let workspaceURL = viewModel.workspaceURL {
            panel.directoryURL = workspaceURL
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setWorkspace(url)
    }

    private func chooseAdditionalDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择额外可写目录"
        panel.prompt = "授权"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = viewModel.workspaceURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.addWritableDirectory(url)
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "添加 Agent 附件"
        panel.prompt = "添加"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = viewModel.workspaceURL
        guard panel.runModal() == .OK else { return }
        viewModel.addAttachments(panel.urls)
    }

    private func sendDraft() {
        let prompt = viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !viewModel.draftAttachments.isEmpty),
              let selectedTarget else { return }
        viewModel.draft = ""
        viewModel.send(prompt, target: selectedTarget)
    }
}

struct AgentRunProgress: Equatable {
    var currentStep: Int?
    var totalSteps: Int?
    var completedOperations = 0
    var changedFiles = 0
    var addedLines = 0
    var deletedLines = 0
}

private struct AgentFileLineStats: Equatable, Sendable {
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}

private struct AgentWorkspaceChangeSnapshot: Sendable {
    var files: [String: AgentFileLineStats]

    nonisolated init(files: [String: AgentFileLineStats] = [:]) {
        self.files = files
    }
}

private struct StagedAgentAttachments: Sendable {
    let attachments: [AgentAttachmentRecord]
    let directoryURL: URL?
}

private enum AgentAttachmentError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            "无法读取附件“\(name)”，请重新添加后再试。"
        }
    }
}

private enum AgentContextHandoffEvent {
    case compaction
    case modelSwitch(String)
}

@MainActor
final class AgentWorkspaceViewModel: ObservableObject {
    @Published private(set) var projects: [AgentProjectRecord] = []
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedSessionID: UUID?
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var additionalWritableURLs: [URL] = []
    @Published private(set) var entries: [AgentTranscriptEntry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "准备就绪"
    @Published private(set) var threadID: String?
    @Published private(set) var codexStatus = "检查 Codex"
    @Published private(set) var codexStatusIcon = "clock"
    @Published private(set) var claudeStatus = "检查 Claude Code"
    @Published private(set) var claudeStatusIcon = "clock"
    @Published private(set) var grokStatus = "检查 Grok Build"
    @Published private(set) var grokStatusIcon = "clock"
    @Published private(set) var installingCLI: AgentEngineKind?
    @Published private(set) var cliInstallationError: String?
    @Published private(set) var selectedTargetID = ""
    @Published private(set) var reasoningEffortOverrides: [String: AgentReasoningEffort] = [:]
    @Published private(set) var runProgress = AgentRunProgress()
    @Published private(set) var draftAttachments: [AgentAttachmentRecord] = []
    @Published var draft = ""

    private let provider = AgentProviderRouter()
    private let historyStore = AgentHistoryStore()
    private var runTask: Task<Void, Never>?
    private var activeTargetID: String?
    private var contextSummary: String?
    private var contextHandoffPending = false
    private var lastCompactedAt: Date?
    private var compactedEntryCount = 0
    private var contextGeneration = 0
    private var lastInputTokens: Int?
    private var runStartedAt: Date?
    private var runCompletionRecorded = false
    private var runBaselineSnapshot = AgentWorkspaceChangeSnapshot()
    private var runTouchedPaths: Set<String> = []
    private var didRestoreHistory = false
    private var codexAvailable: Bool?
    private var claudeAvailable: Bool?
    private var grokAvailable: Bool?
    private let legacyWorkspaceDefaultsKey = "agent.workspace.path"
    private let legacyWritableDirectoriesDefaultsKey = "agent.additional-writable-paths"
    private let selectedTargetDefaultsKey = "agent.selected-target-id"
    private let reasoningEffortDefaultsKey = "agent.reasoning-effort-overrides"

    init() {
        selectedTargetID = UserDefaults.standard.string(forKey: "agent.selected-target-id")
            ?? ""
        let storedEfforts = UserDefaults.standard.dictionary(
            forKey: "agent.reasoning-effort-overrides"
        ) as? [String: String] ?? [:]
        reasoningEffortOverrides = storedEfforts.reduce(into: [:]) { result, item in
            if let effort = AgentReasoningEffort(rawValue: item.value) {
                result[item.key] = effort
            }
        }
    }

    func restoreWorkspace() {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true

        do {
            let archive = try historyStore.load()
            projects = archive.projects
            if let projectID = archive.selectedProjectID,
               projects.contains(where: { $0.id == projectID }) {
                selectProject(projectID, preferredSessionID: archive.selectedSessionID, persists: false)
            } else if let project = sortedProjects.first {
                selectProject(project.id, preferredSessionID: nil, persists: false)
            }
            if !projects.isEmpty {
                clearLegacyWorkspaceDefaults()
            }
        } catch {
            statusText = "历史记录读取失败：\(error.localizedDescription)"
            return
        }

        migrateLegacyWorkspaceIfNeeded()
    }

    func setWorkspace(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let project = projects.first(where: { $0.path == standardized.path }) {
            selectProject(project.id)
            return
        }
        cancel()
        let session = AgentSessionRecord(targetID: selectedTargetID.nilIfEmpty)
        let project = AgentProjectRecord(path: standardized.path, sessions: [session])
        projects.append(project)
        selectedProjectID = project.id
        selectedSessionID = session.id
        load(project: project, session: session)
        persistHistory()
    }

    var sortedProjects: [AgentProjectRecord] {
        projects.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func sessions(for projectID: UUID) -> [AgentSessionRecord] {
        guard let project = projects.first(where: { $0.id == projectID }) else { return [] }
        return project.sessions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.createdAt > $1.createdAt
        }
    }

    var selectedSessionTitle: String {
        currentSession?.title ?? "新会话"
    }

    func selectProject(_ projectID: UUID) {
        selectProject(projectID, preferredSessionID: nil, persists: true)
    }

    func selectSession(_ sessionID: UUID, in projectID: UUID) {
        guard !isRunning,
              let project = projects.first(where: { $0.id == projectID }),
              let session = project.sessions.first(where: { $0.id == sessionID }) else { return }
        selectedProjectID = projectID
        selectedSessionID = sessionID
        load(project: project, session: session)
        persistHistory()
    }

    func deleteProject(_ projectID: UUID) {
        guard !isRunning,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let wasSelected = selectedProjectID == projectID
        projects.remove(at: projectIndex)
        if projects.isEmpty {
            clearLegacyWorkspaceDefaults()
        }

        if wasSelected {
            if let fallbackProject = sortedProjects.first {
                selectProject(fallbackProject.id, preferredSessionID: nil, persists: false)
            } else {
                clearWorkspaceSelection()
            }
        }
        persistHistory()
    }

    func deleteSession(_ sessionID: UUID, in projectID: UUID) {
        guard !isRunning,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let wasSelected = selectedProjectID == projectID && selectedSessionID == sessionID
        projects[projectIndex].sessions.remove(at: sessionIndex)
        projects[projectIndex].updatedAt = .now

        if wasSelected {
            if let fallbackSession = sessions(for: projectID).first {
                selectedSessionID = fallbackSession.id
                load(project: projects[projectIndex], session: fallbackSession)
            } else {
                load(projectWithoutSession: projects[projectIndex])
            }
        }
        persistHistory()
    }

    func selectTarget(_ target: AgentProviderTarget) {
        guard !isRunning, target.id != selectedTargetID else { return }
        selectedTargetID = target.id
        UserDefaults.standard.set(target.id, forKey: selectedTargetDefaultsKey)
        guard selectedProjectID != nil else {
            activeTargetID = target.id
            return
        }
        if entries.isEmpty {
            activeTargetID = target.id
            threadID = nil
            updateCurrentSession()
        } else if let workspaceURL {
            activeTargetID = target.id
            let plan = AgentContextCompactor.recoveryPlan(
                entries: entries,
                projectPath: workspaceURL.path,
                reason: "已切换到 \(target.title)"
            )
            applyContextHandoff(plan, event: .modelSwitch(target.title))
            statusText = "已切换到 \(target.title)，可继续当前任务"
        }
    }

    func reconcileTargetIDs(_ targetIDs: [String]) {
        guard !targetIDs.contains(selectedTargetID) else { return }
        guard let firstTargetID = targetIDs.first else {
            selectedTargetID = ""
            activeTargetID = nil
            UserDefaults.standard.removeObject(forKey: selectedTargetDefaultsKey)
            return
        }
        selectedTargetID = firstTargetID
        activeTargetID = firstTargetID
        threadID = nil
        UserDefaults.standard.set(firstTargetID, forKey: selectedTargetDefaultsKey)
        updateCurrentSession()
    }

    func reasoningEffort(for target: AgentProviderTarget) -> AgentReasoningEffort {
        let effort = reasoningEffortOverrides[target.id] ?? target.defaultReasoningEffort
        return target.engine.supportedReasoningEfforts.contains(effort) ? effort : .automatic
    }

    func hasReasoningEffortOverride(for target: AgentProviderTarget) -> Bool {
        reasoningEffortOverrides[target.id] != nil
    }

    func selectReasoningEffort(
        _ effort: AgentReasoningEffort,
        for target: AgentProviderTarget
    ) {
        guard target.engine.supportedReasoningEfforts.contains(effort) else { return }
        reasoningEffortOverrides[target.id] = effort
        persistReasoningEfforts()
    }

    func resetReasoningEffort(for target: AgentProviderTarget) {
        reasoningEffortOverrides.removeValue(forKey: target.id)
        persistReasoningEfforts()
    }

    func startNewSession() {
        guard !isRunning, let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let session = AgentSessionRecord(targetID: selectedTargetID.nilIfEmpty)
        projects[projectIndex].sessions.append(session)
        projects[projectIndex].updatedAt = .now
        selectedSessionID = session.id
        load(project: projects[projectIndex], session: session)
        persistHistory()
    }

    func addWritableDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != workspaceURL,
              !additionalWritableURLs.contains(where: { $0.path == standardized.path }) else { return }
        additionalWritableURLs.append(standardized)
        additionalWritableURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        updateProjectWritableDirectories()
    }

    func removeWritableDirectory(_ url: URL) {
        additionalWritableURLs.removeAll { $0.path == url.path }
        updateProjectWritableDirectories()
    }

    func addAttachments(_ urls: [URL]) {
        guard !isRunning else { return }
        var rejectedCount = 0
        for url in urls {
            guard draftAttachments.count < 10 else {
                rejectedCount += 1
                continue
            }
            let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try? standardizedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: standardizedURL.path),
                  (values?.fileSize ?? 0) <= 100_000_000,
                  !draftAttachments.contains(where: { $0.path == standardizedURL.path }) else {
                rejectedCount += 1
                continue
            }
            draftAttachments.append(AgentAttachmentRecord(url: standardizedURL))
        }
        if rejectedCount > 0 {
            statusText = "部分文件未添加：最多 10 个附件，单个文件不超过 100 MB"
        } else if !urls.isEmpty {
            statusText = "已添加 \(draftAttachments.count) 个附件"
        }
    }

    func removeAttachment(_ attachmentID: UUID) {
        guard !isRunning else { return }
        draftAttachments.removeAll { $0.id == attachmentID }
    }

    func clearAttachments() {
        guard !isRunning else { return }
        draftAttachments = []
    }

    func send(_ prompt: String, target: AgentProviderTarget) {
        guard let workspaceURL, !isRunning else { return }
        if selectedSessionID == nil {
            startNewSession()
        }
        guard selectedSessionID != nil else { return }
        if activeTargetID != nil, activeTargetID != target.id {
            threadID = nil
        }
        let attachments = draftAttachments
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty || !attachments.isEmpty else { return }
        let displayPrompt = normalizedPrompt.isEmpty
            ? "处理附件：\(attachments.map(\.displayName).joined(separator: "、"))"
            : normalizedPrompt
        guard !displayPrompt.isEmpty else { return }

        if let session = currentSession,
           let plan = AgentContextCompactor.compactionPlan(
               for: session,
               projectPath: workspaceURL.path,
               engine: target.engine,
               pendingPrompt: displayPrompt
           ) {
            applyContextCompaction(plan)
        } else if threadID == nil,
                  !entries.isEmpty,
                  !contextHandoffPending,
                  entries.contains(where: { $0.kind == .assistant || $0.kind == .command }) {
            let plan = AgentContextCompactor.recoveryPlan(
                entries: entries,
                projectPath: workspaceURL.path,
                reason: "已恢复为新的 CLI 会话"
            )
            applyContextCompaction(plan)
        }

        activeTargetID = target.id
        let recoverySourceEntryCount = entries.count
        entries.append(.user(displayPrompt, attachments: attachments))
        draftAttachments = []
        if currentSession?.entries.isEmpty == true {
            setCurrentSessionTitle(from: displayPrompt)
        }
        isRunning = true
        runStartedAt = .now
        runCompletionRecorded = false
        runProgress = AgentRunProgress()
        runBaselineSnapshot = AgentWorkspaceChangeSnapshot()
        runTouchedPaths = []
        statusText = "正在启动 Agent"
        updateCurrentSession()

        let writableURLs = additionalWritableURLs
        let activeThreadID = threadID
        let contextHandoff = contextHandoffPending ? contextSummary : nil
        let reasoningEffort = reasoningEffort(for: target)
        runTask = Task { [weak self] in
            guard let self else { return }
            var stagingDirectoryURL: URL?
            defer {
                if let stagingDirectoryURL {
                    try? FileManager.default.removeItem(at: stagingDirectoryURL)
                }
            }
            do {
                let stagedAttachments = try await Task.detached(priority: .utility) {
                    try Self.stageAttachments(attachments, workspaceURL: workspaceURL)
                }.value
                stagingDirectoryURL = stagedAttachments.directoryURL
                runBaselineSnapshot = await Task.detached(priority: .utility) {
                    Self.workspaceChangeSnapshot(at: workspaceURL)
                }.value
                try Task.checkCancellation()
                let request = AgentRunRequest(
                    prompt: displayPrompt,
                    attachments: stagedAttachments.attachments,
                    workspaceURL: workspaceURL,
                    additionalWritableURLs: writableURLs
                        + [stagedAttachments.directoryURL].compactMap { $0 },
                    target: target,
                    threadID: activeThreadID,
                    contextHandoff: contextHandoff,
                    reasoningEffort: reasoningEffort
                )

                var receivedSubstantiveEvent = false
                @MainActor func runProvider(_ request: AgentRunRequest) async throws {
                    for try await event in provider.run(request) {
                        receivedSubstantiveEvent = receivedSubstantiveEvent || event.indicatesSubstantiveProgress
                        await handle(event)
                    }
                }

                do {
                    try await runProvider(request)
                } catch {
                    guard activeThreadID != nil,
                          !receivedSubstantiveEvent,
                          Self.shouldRetryFreshThread(after: error) else { throw error }
                    let recoveryEntries = Array(entries.prefix(recoverySourceEntryCount))
                    let recoveryPlan = AgentContextCompactor.recoveryPlan(
                        entries: recoveryEntries,
                        projectPath: workspaceURL.path,
                        reason: "原会话无法恢复，已自动接续"
                    )
                    applyContextCompaction(recoveryPlan)
                    statusText = "正在接续新的 Agent 会话"
                    let retryRequest = AgentRunRequest(
                        prompt: displayPrompt,
                        attachments: stagedAttachments.attachments,
                        workspaceURL: workspaceURL,
                        additionalWritableURLs: writableURLs
                            + [stagedAttachments.directoryURL].compactMap { $0 },
                        target: target,
                        threadID: nil,
                        contextHandoff: recoveryPlan.summary,
                        reasoningEffort: reasoningEffort
                    )
                    try await runProvider(retryRequest)
                }
                if !runCompletionRecorded {
                    await refreshRunChangeStats()
                    recordCompletion(usage: nil)
                }
                isRunning = false
                statusText = "任务已完成"
                updateCurrentSession()
            } catch is CancellationError {
                isRunning = false
                statusText = "任务已停止"
            } catch {
                isRunning = false
                if Task.isCancelled {
                    statusText = "任务已停止"
                } else {
                    statusText = "任务失败"
                    entries.append(.error(error.localizedDescription))
                    updateCurrentSession()
                }
            }
            runStartedAt = nil
            runTask = nil
        }
    }

    func cancel() {
        guard isRunning else { return }
        provider.cancel()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        statusText = "任务已停止"
        runStartedAt = nil
        runCompletionRecorded = false
        updateCurrentSession()
    }

    func refreshCLIStatuses() {
        refreshCodexStatus()
        refreshClaudeStatus()
        refreshGrokStatus()
    }

    func performCLIAction(for engine: AgentEngineKind) {
        if canInstallCLI(engine) {
            installCLI(engine)
        } else {
            refreshCLIStatus(for: engine)
        }
    }

    func cliActionStatus(for engine: AgentEngineKind) -> (text: String, icon: String) {
        if installingCLI == engine {
            return ("正在安装 \(engine.channelDisplayName)", "arrow.down.circle")
        }
        if canInstallCLI(engine) {
            return ("安装 \(engine.channelDisplayName) CLI", "arrow.down.circle")
        }
        return cliStatus(for: engine)
    }

    func cliActionHelp(for engine: AgentEngineKind) -> String {
        canInstallCLI(engine)
            ? "安装 \(engine.displayName)"
            : "检查 \(engine.displayName) 状态"
    }

    func dismissCLIInstallationError() {
        cliInstallationError = nil
    }

    func cliStatus(for engine: AgentEngineKind) -> (text: String, icon: String) {
        switch engine {
        case .codexCLI:
            (codexStatus, codexStatusIcon)
        case .claudeCodeCLI:
            (claudeStatus, claudeStatusIcon)
        case .grokBuildCLI:
            (grokStatus, grokStatusIcon)
        case .disabled:
            ("Agent 已停用", "minus.circle")
        }
    }

    private func refreshCodexStatus() {
        guard installingCLI != .codexCLI else { return }
        codexAvailable = nil
        codexStatus = "检查 Codex"
        codexStatusIcon = "clock"
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.probeCodexStatus()
            }.value
            codexStatus = result.text
            codexStatusIcon = result.icon
            codexAvailable = result.isAvailable
        }
    }

    private func refreshClaudeStatus() {
        guard installingCLI != .claudeCodeCLI else { return }
        claudeAvailable = nil
        claudeStatus = "检查 Claude Code"
        claudeStatusIcon = "clock"
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.probeClaudeStatus()
            }.value
            claudeStatus = result.text
            claudeStatusIcon = result.icon
            claudeAvailable = result.isAvailable
        }
    }

    private func refreshGrokStatus() {
        guard installingCLI != .grokBuildCLI else { return }
        grokAvailable = nil
        grokStatus = "检查 Grok Build"
        grokStatusIcon = "clock"
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.probeGrokStatus()
            }.value
            grokStatus = result.text
            grokStatusIcon = result.icon
            grokAvailable = result.isAvailable
        }
    }

    private func canInstallCLI(_ engine: AgentEngineKind) -> Bool {
        guard installingCLI == nil, AgentCLIInstaller.command(for: engine) != nil else { return false }
        switch engine {
        case .codexCLI:
            return codexAvailable == false
        case .claudeCodeCLI:
            return claudeAvailable == false
        case .grokBuildCLI, .disabled:
            return false
        }
    }

    private func installCLI(_ engine: AgentEngineKind) {
        guard canInstallCLI(engine) else { return }
        installingCLI = engine
        cliInstallationError = nil
        setCLIStatus(
            for: engine,
            text: "正在安装 \(engine.channelDisplayName) CLI",
            icon: "arrow.down.circle"
        )

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AgentCLIInstaller.install(engine)
            }.value
            guard let self, installingCLI == engine else { return }
            installingCLI = nil
            if result.succeeded {
                setCLIStatus(for: engine, text: "安装完成，正在检查", icon: "checkmark.circle")
                refreshCLIStatus(for: engine)
            } else {
                setCLIAvailability(false, for: engine)
                setCLIStatus(
                    for: engine,
                    text: "\(engine.channelDisplayName) 安装失败",
                    icon: "exclamationmark.triangle"
                )
                let detail = result.output.isEmpty
                    ? "安装命令退出码：\(result.exitCode)"
                    : result.output
                cliInstallationError = String(detail.suffix(3_000))
            }
        }
    }

    private func refreshCLIStatus(for engine: AgentEngineKind) {
        switch engine {
        case .codexCLI:
            refreshCodexStatus()
        case .claudeCodeCLI:
            refreshClaudeStatus()
        case .grokBuildCLI:
            refreshGrokStatus()
        case .disabled:
            break
        }
    }

    private func setCLIStatus(for engine: AgentEngineKind, text: String, icon: String) {
        switch engine {
        case .codexCLI:
            codexStatus = text
            codexStatusIcon = icon
        case .claudeCodeCLI:
            claudeStatus = text
            claudeStatusIcon = icon
        case .grokBuildCLI:
            grokStatus = text
            grokStatusIcon = icon
        case .disabled:
            break
        }
    }

    private func setCLIAvailability(_ isAvailable: Bool, for engine: AgentEngineKind) {
        switch engine {
        case .codexCLI:
            codexAvailable = isAvailable
        case .claudeCodeCLI:
            claudeAvailable = isAvailable
        case .grokBuildCLI:
            grokAvailable = isAvailable
        case .disabled:
            break
        }
    }

    private func persistReasoningEfforts() {
        UserDefaults.standard.set(
            reasoningEffortOverrides.mapValues(\.rawValue),
            forKey: reasoningEffortDefaultsKey
        )
    }

    private func handle(_ event: AgentEvent) async {
        switch event {
        case .threadStarted(let id):
            threadID = id
            contextHandoffPending = false
            updateCurrentSession()
        case .status(let text):
            statusText = text
        case .assistant(let text):
            entries.append(.assistant(text))
            updateCurrentSession()
        case .command(let command, let output, let exitCode):
            entries.append(.command(command: command, output: output, exitCode: exitCode))
            runProgress.completedOperations += 1
            updateCurrentSession()
        case .fileChange(let summary):
            entries.append(.fileChange(summary))
            runProgress.completedOperations += 1
            runTouchedPaths.formUnion(changedPaths(from: summary))
            updateCurrentSession()
            await refreshRunChangeStats()
        case .planProgress(let currentStep, let totalSteps):
            runProgress.currentStep = min(max(1, currentStep), max(1, totalSteps))
            runProgress.totalSteps = max(1, totalSteps)
        case .warning(let text):
            if entries.last?.kind != .warning || entries.last?.content != text {
                entries.append(.warning(text))
                updateCurrentSession()
            }
        case .completed(let usage):
            if let inputTokens = usage?.inputTokens {
                lastInputTokens = inputTokens
            }
            await refreshRunChangeStats()
            recordCompletion(usage: usage)
            statusText = usage.map {
                "完成 · 输入 \($0.inputTokens ?? 0) / 输出 \($0.outputTokens ?? 0) tokens"
            } ?? "任务已完成"
        }
    }

    private func recordCompletion(usage: AgentUsage?) {
        guard !runCompletionRecorded else { return }
        let duration = max(0, Int(Date().timeIntervalSince(runStartedAt ?? .now) * 1_000))
        let fallbackTotalSteps = runProgress.completedOperations > 0
            ? runProgress.completedOperations
            : nil
        entries.append(
            .completion(
                durationMilliseconds: duration,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                currentStep: runProgress.totalSteps ?? runProgress.currentStep ?? fallbackTotalSteps,
                totalSteps: runProgress.totalSteps ?? fallbackTotalSteps,
                changedFiles: runProgress.changedFiles,
                addedLines: runProgress.addedLines,
                deletedLines: runProgress.deletedLines
            )
        )
        runCompletionRecorded = true
        updateCurrentSession()
    }

    private func applyContextCompaction(_ plan: AgentContextCompactionPlan) {
        applyContextHandoff(plan, event: .compaction)
        statusText = "上下文已压缩，准备接续"
    }

    private func applyContextHandoff(
        _ plan: AgentContextCompactionPlan,
        event: AgentContextHandoffEvent
    ) {
        contextSummary = plan.summary
        contextHandoffPending = true
        lastCompactedAt = .now
        compactedEntryCount = plan.sourceEntryCount
        contextGeneration += 1
        lastInputTokens = nil
        threadID = nil
        switch event {
        case .compaction:
            entries.append(.contextCompact(generation: contextGeneration, reason: plan.reason))
        case .modelSwitch(let modelName):
            entries.append(.modelSwitch(to: modelName, generation: contextGeneration))
        }
        updateCurrentSession()
    }

    private static func shouldRetryFreshThread(after error: Error) -> Bool {
        guard case let AgentProviderError.processFailed(message) = error else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return ["resume", "session", "thread", "conversation", "rollout", "not found", "cannot continue"]
            .contains { normalized.contains($0) }
    }

    private func refreshRunChangeStats() async {
        guard let workspaceURL else { return }
        let currentSnapshot = await Task.detached(priority: .utility) {
            Self.workspaceChangeSnapshot(at: workspaceURL)
        }.value
        let baselineFiles = runBaselineSnapshot.files
        let currentFiles = currentSnapshot.files
        let allPaths = Set(baselineFiles.keys).union(currentFiles.keys)
        var changedPaths: Set<String> = []
        var additions = 0
        var deletions = 0

        for path in allPaths {
            let baseline = baselineFiles[path]
            let current = currentFiles[path]
            guard baseline != current else { continue }
            changedPaths.insert(path)

            let baselineAdditions = baseline?.additions ?? 0
            let baselineDeletions = baseline?.deletions ?? 0
            let currentAdditions = current?.additions ?? 0
            let currentDeletions = current?.deletions ?? 0
            additions += max(0, currentAdditions - baselineAdditions)
                + max(0, baselineDeletions - currentDeletions)
            deletions += max(0, currentDeletions - baselineDeletions)
                + max(0, baselineAdditions - currentAdditions)
        }

        runProgress.changedFiles = changedPaths.union(runTouchedPaths).count
        runProgress.addedLines = additions
        runProgress.deletedLines = deletions
    }

    private func changedPaths(from summary: String) -> Set<String> {
        guard let workspaceURL else { return [] }
        let workspacePath = workspaceURL.standardizedFileURL.path
        return Set(summary.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let candidate: String
            if let separator = line.firstIndex(of: ":") {
                candidate = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                candidate = line
            }
            let unquoted = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !unquoted.isEmpty, unquoted != "文件已更新" else { return nil }
            if unquoted.hasPrefix("/") {
                guard unquoted == workspacePath || unquoted.hasPrefix(workspacePath + "/") else {
                    return nil
                }
                return String(unquoted.dropFirst(workspacePath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return unquoted.hasPrefix("./") ? String(unquoted.dropFirst(2)) : unquoted
        }.filter { !$0.isEmpty })
    }

    nonisolated private static func workspaceChangeSnapshot(
        at workspaceURL: URL
    ) -> AgentWorkspaceChangeSnapshot {
        var snapshot = AgentWorkspaceChangeSnapshot()
        let diffData = gitOutput(
            ["-c", "core.quotepath=false", "diff", "--numstat", "HEAD", "--"],
            at: workspaceURL
        ) ?? Data()

        if let diffText = String(data: diffData, encoding: .utf8) {
            for line in diffText.split(separator: "\n") {
                let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard columns.count == 3 else { continue }
                let isBinary = columns[0] == "-" || columns[1] == "-"
                snapshot.files[String(columns[2])] = AgentFileLineStats(
                    additions: Int(columns[0]) ?? 0,
                    deletions: Int(columns[1]) ?? 0,
                    isBinary: isBinary
                )
            }
        }

        guard let untrackedData = gitOutput(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: workspaceURL
        ) else {
            return snapshot
        }
        for pathData in untrackedData.split(separator: 0) {
            guard let path = String(data: Data(pathData), encoding: .utf8), !path.isEmpty else { continue }
            snapshot.files[path] = untrackedFileStats(
                at: workspaceURL.appendingPathComponent(path, isDirectory: false)
            )
        }
        return snapshot
    }

    nonisolated private static func gitOutput(
        _ arguments: [String],
        at workspaceURL: URL
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workspaceURL.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    nonisolated private static func untrackedFileStats(at url: URL) -> AgentFileLineStats {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= 8_000_000,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return AgentFileLineStats(additions: 0, deletions: 0, isBinary: true)
        }
        guard !data.contains(0) else {
            return AgentFileLineStats(additions: 0, deletions: 0, isBinary: true)
        }
        let newlineCount = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let lineCount = data.isEmpty || data.last == 0x0A ? newlineCount : newlineCount + 1
        return AgentFileLineStats(additions: lineCount, deletions: 0, isBinary: false)
    }

    nonisolated private static func stageAttachments(
        _ attachments: [AgentAttachmentRecord],
        workspaceURL: URL
    ) throws -> StagedAgentAttachments {
        guard !attachments.isEmpty else {
            return StagedAgentAttachments(attachments: [], directoryURL: nil)
        }
        let workspacePath = workspaceURL.standardizedFileURL.path
        let externalAttachments = attachments.filter {
            let path = $0.url.standardizedFileURL.path
            return path != workspacePath && !path.hasPrefix(workspacePath + "/")
        }
        guard !externalAttachments.isEmpty else {
            return StagedAgentAttachments(attachments: attachments, directoryURL: nil)
        }

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMac-AgentAttachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            var stagedByID: [UUID: AgentAttachmentRecord] = [:]
            for attachment in externalAttachments {
                guard FileManager.default.isReadableFile(atPath: attachment.path) else {
                    throw AgentAttachmentError.unavailable(attachment.displayName)
                }
                let attachmentDirectory = stagingURL
                    .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: attachmentDirectory,
                    withIntermediateDirectories: true
                )
                let destinationURL = attachmentDirectory
                    .appendingPathComponent(attachment.displayName, isDirectory: false)
                try FileManager.default.copyItem(at: attachment.url, to: destinationURL)
                stagedByID[attachment.id] = AgentAttachmentRecord(
                    id: attachment.id,
                    path: destinationURL.path,
                    displayName: attachment.displayName,
                    contentTypeIdentifier: attachment.contentTypeIdentifier,
                    byteSize: attachment.byteSize
                )
            }
            let stagedAttachments = attachments.map { stagedByID[$0.id] ?? $0 }
            return StagedAgentAttachments(
                attachments: stagedAttachments,
                directoryURL: stagingURL
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private var currentSession: AgentSessionRecord? {
        guard let projectID = selectedProjectID, let sessionID = selectedSessionID else { return nil }
        return projects.first(where: { $0.id == projectID })?
            .sessions.first(where: { $0.id == sessionID })
    }

    private func selectProject(
        _ projectID: UUID,
        preferredSessionID: UUID?,
        persists: Bool
    ) {
        guard !isRunning,
              let project = projects.first(where: { $0.id == projectID }) else { return }
        let session = preferredSessionID.flatMap { sessionID in
            project.sessions.first(where: { $0.id == sessionID })
        } ?? sessions(for: projectID).first

        selectedProjectID = projectID
        if let session {
            selectedSessionID = session.id
            load(project: project, session: session)
        } else {
            load(projectWithoutSession: project)
        }
        if persists { persistHistory() }
    }

    private func load(project: AgentProjectRecord, session: AgentSessionRecord) {
        workspaceURL = URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL
        additionalWritableURLs = existingDirectories(from: project.additionalWritablePaths)
        entries = session.entries
        threadID = session.threadID
        contextSummary = session.contextSummary
        contextHandoffPending = session.contextHandoffPending ?? false
        lastCompactedAt = session.lastCompactedAt
        compactedEntryCount = session.compactedEntryCount ?? 0
        contextGeneration = session.contextGeneration ?? 0
        lastInputTokens = session.lastInputTokens
        activeTargetID = session.targetID ?? selectedTargetID.nilIfEmpty
        if let targetID = session.targetID {
            selectedTargetID = targetID
            UserDefaults.standard.set(targetID, forKey: selectedTargetDefaultsKey)
        }
        statusText = entries.isEmpty ? "准备就绪" : "已恢复历史会话"
        draft = ""
        draftAttachments = []
    }

    private func load(projectWithoutSession project: AgentProjectRecord) {
        selectedSessionID = nil
        workspaceURL = URL(fileURLWithPath: project.path, isDirectory: true).standardizedFileURL
        additionalWritableURLs = existingDirectories(from: project.additionalWritablePaths)
        entries = []
        threadID = nil
        contextSummary = nil
        contextHandoffPending = false
        lastCompactedAt = nil
        compactedEntryCount = 0
        contextGeneration = 0
        lastInputTokens = nil
        activeTargetID = selectedTargetID.nilIfEmpty
        statusText = "准备新会话"
        draft = ""
        draftAttachments = []
    }

    private func clearWorkspaceSelection() {
        selectedProjectID = nil
        selectedSessionID = nil
        workspaceURL = nil
        additionalWritableURLs = []
        entries = []
        threadID = nil
        contextSummary = nil
        contextHandoffPending = false
        lastCompactedAt = nil
        compactedEntryCount = 0
        contextGeneration = 0
        lastInputTokens = nil
        activeTargetID = selectedTargetID.nilIfEmpty
        statusText = "请选择项目"
        draft = ""
        draftAttachments = []
    }

    private func updateCurrentSession() {
        guard let projectID = selectedProjectID, let sessionID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let now = Date.now
        projects[projectIndex].sessions[sessionIndex].entries = entries
        projects[projectIndex].sessions[sessionIndex].threadID = threadID
        projects[projectIndex].sessions[sessionIndex].targetID = activeTargetID ?? selectedTargetID.nilIfEmpty
        projects[projectIndex].sessions[sessionIndex].contextSummary = contextSummary
        projects[projectIndex].sessions[sessionIndex].contextHandoffPending = contextHandoffPending
        projects[projectIndex].sessions[sessionIndex].lastCompactedAt = lastCompactedAt
        projects[projectIndex].sessions[sessionIndex].compactedEntryCount = compactedEntryCount
        projects[projectIndex].sessions[sessionIndex].contextGeneration = contextGeneration
        projects[projectIndex].sessions[sessionIndex].lastInputTokens = lastInputTokens
        projects[projectIndex].sessions[sessionIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        persistHistory()
    }

    private func setCurrentSessionTitle(from prompt: String) {
        guard let projectID = selectedProjectID, let sessionID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let singleLine = prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projects[projectIndex].sessions[sessionIndex].title = String(singleLine.prefix(32))
    }

    private func updateProjectWritableDirectories() {
        guard let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[projectIndex].additionalWritablePaths = additionalWritableURLs.map(\.path)
        projects[projectIndex].updatedAt = .now
        threadID = nil
        updateCurrentSession()
    }

    private func existingDirectories(from paths: [String]) -> [URL] {
        paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
    }

    private func persistHistory() {
        let archive = AgentHistoryArchive(
            selectedProjectID: selectedProjectID,
            selectedSessionID: selectedSessionID,
            projects: projects
        )
        do {
            try historyStore.save(archive)
        } catch {
            statusText = "历史记录保存失败：\(error.localizedDescription)"
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() {
        guard projects.isEmpty,
              let path = UserDefaults.standard.string(forKey: legacyWorkspaceDefaultsKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let writablePaths = UserDefaults.standard.stringArray(
            forKey: legacyWritableDirectoriesDefaultsKey
        ) ?? []
        let session = AgentSessionRecord(targetID: selectedTargetID.nilIfEmpty)
        let project = AgentProjectRecord(
            path: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path,
            additionalWritablePaths: writablePaths,
            sessions: [session]
        )
        projects = [project]
        selectedProjectID = project.id
        selectedSessionID = session.id
        load(project: project, session: session)
        clearLegacyWorkspaceDefaults()
        persistHistory()
    }

    private func clearLegacyWorkspaceDefaults() {
        UserDefaults.standard.removeObject(forKey: legacyWorkspaceDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyWritableDirectoriesDefaultsKey)
    }

    nonisolated private static func probeCodexStatus() -> (text: String, icon: String, isAvailable: Bool) {
        probeCLI(command: "codex --version", availableText: "Codex CLI 可用", missingText: "未安装 Codex")
    }

    nonisolated private static func probeClaudeStatus() -> (text: String, icon: String, isAvailable: Bool) {
        probeCLI(
            command: "claude --version",
            availableText: "Claude Code 可用",
            missingText: "未安装 Claude Code"
        )
    }

    nonisolated private static func probeGrokStatus() -> (text: String, icon: String, isAvailable: Bool) {
        probeCLI(
            command: "grok --version",
            availableText: "Grok Build 可用",
            missingText: "未安装 Grok Build"
        )
    }

    nonisolated private static func probeCLI(
        command: String,
        availableText: String,
        missingText: String
    ) -> (text: String, icon: String, isAvailable: Bool) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (missingText, "exclamationmark.triangle", false)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.localizedCaseInsensitiveContains("not found") || process.terminationStatus == 127 {
            return (missingText, "exclamationmark.triangle", false)
        }
        guard process.terminationStatus == 0 else {
            return (missingText, "exclamationmark.triangle", false)
        }
        return (availableText, "checkmark.circle", true)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct AgentTranscriptTurn: Identifiable {
    let id: UUID
    let userEntry: AgentTranscriptEntry?
    let agentEntries: [AgentTranscriptEntry]

    static func grouping(_ entries: [AgentTranscriptEntry]) -> [AgentTranscriptTurn] {
        var turns: [AgentTranscriptTurn] = []
        var userEntry: AgentTranscriptEntry?
        var agentEntries: [AgentTranscriptEntry] = []

        func appendCurrentTurn() {
            guard let id = userEntry?.id ?? agentEntries.first?.id else { return }
            turns.append(
                AgentTranscriptTurn(
                    id: id,
                    userEntry: userEntry,
                    agentEntries: agentEntries
                )
            )
        }

        for entry in entries {
            if case .user = entry.kind {
                appendCurrentTurn()
                userEntry = entry
                agentEntries = []
            } else {
                agentEntries.append(entry)
            }
        }
        appendCurrentTurn()
        return turns
    }
}

private struct AgentEventGroup: Identifiable {
    let id: UUID
    let entries: [AgentTranscriptEntry]

    var isCommandGroup: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.kind == .command }
    }

    static func grouping(_ entries: [AgentTranscriptEntry]) -> [AgentEventGroup] {
        var groups: [AgentEventGroup] = []
        var commands: [AgentTranscriptEntry] = []

        func flushCommands() {
            guard let first = commands.first else { return }
            groups.append(AgentEventGroup(id: first.id, entries: commands))
            commands.removeAll(keepingCapacity: true)
        }

        for entry in entries {
            if entry.kind == .command {
                commands.append(entry)
            } else {
                flushCommands()
                groups.append(AgentEventGroup(id: entry.id, entries: [entry]))
            }
        }
        flushCommands()
        return groups
    }
}

private struct AgentTurnView: View {
    let turn: AgentTranscriptTurn
    let isActive: Bool
    let liveProgress: AgentRunProgress?

    private var eventGroups: [AgentEventGroup] {
        AgentEventGroup.grouping(turn.agentEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let userEntry = turn.userEntry {
                AgentTaskRow(entry: userEntry)
            }

            HStack(alignment: .top, spacing: 0) {
                agentFlow
                    .frame(maxWidth: 860, alignment: .leading)
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentFlow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AeroTheme.deepLeaf)
                    .frame(width: 26, height: 26)
                    .background(AeroTheme.leaf.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("Agent")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(AeroTheme.deepLeaf)

                Spacer()

                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AeroTheme.deepLeaf)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if turn.agentEntries.isEmpty {
                Divider().opacity(0.34)
                Text("正在准备任务...")
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            } else {
                Divider().opacity(0.34)
                ForEach(Array(eventGroups.enumerated()), id: \.element.id) { index, group in
                    if group.isCommandGroup {
                        AgentCommandGroupRow(entries: group.entries)
                    } else if let entry = group.entries.first, entry.kind == .completion {
                        AgentCompletionRow(entry: entry)
                    } else if let entry = group.entries.first {
                        AgentEventRow(entry: entry)
                    }
                    if index < eventGroups.count - 1 {
                        Divider()
                            .opacity(0.28)
                            .padding(.leading, 52)
                    }
                }
            }

            if isActive,
               !turn.agentEntries.contains(where: { $0.kind == .completion }),
               let liveProgress {
                Divider().opacity(0.28)
                AgentProgressSummaryRow(progress: liveProgress, isActive: true)
            }
        }
        .background(Color.white.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AeroTheme.deepLeaf.opacity(0.2), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(AeroTheme.deepLeaf.opacity(0.72))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
        .shadow(color: AeroTheme.deepSky.opacity(0.09), radius: 10, y: 4)
    }
}

private struct AgentCommandGroupRow: View {
    let entries: [AgentTranscriptEntry]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(commandColor)
                    .frame(width: 28, height: 28)
                    .background(commandColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entries.count == 1 ? "Terminal" : "运行了 \(entries.count) 条终端命令")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundStyle(commandColor)
                        Spacer()
                        Text(exitSummary)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(hasFailure ? AeroTheme.destructive : AeroTheme.deepLeaf)
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AeroTheme.secondaryText)
                        .help(isExpanded ? "收起终端详情" : "展开终端详情")
                    }

                    Text(commandPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(outputSummary)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.faintText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                Divider().opacity(0.28)
                VStack(spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        commandDetail(entry, index: index)
                        if index < entries.count - 1 {
                            Divider().opacity(0.24)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(commandColor.opacity(0.035))
    }

    private func commandDetail(_ entry: AgentTranscriptEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entries.count == 1 ? "命令" : "命令 \(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AeroTheme.faintText)
                Spacer()
                if let exitCode = entry.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? AeroTheme.deepLeaf : AeroTheme.destructive)
                }
            }
            Text(entry.content)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AeroTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail = entry.detail, !detail.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AeroTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: 240)
                .scrollIndicators(.visible)
                .padding(10)
                .background(Color(red: 236 / 255, green: 247 / 255, blue: 250 / 255))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var commandPreview: String {
        if entries.count == 1 {
            return entries[0].content.replacingOccurrences(of: "\n", with: " ")
        }
        return entries
            .prefix(3)
            .map { $0.content.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "  ·  ")
    }

    private var outputSummary: String {
        let details = entries.compactMap(\.detail).filter { !$0.isEmpty }
        let lineCount = details.reduce(0) {
            $0 + $1.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        let byteCount = details.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) }
        guard lineCount > 0 else { return "无输出" }
        return "\(lineCount) 行输出 · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
    }

    private var hasFailure: Bool {
        entries.contains { ($0.exitCode ?? 0) != 0 }
    }

    private var exitSummary: String {
        if entries.count == 1 {
            return "exit \(entries[0].exitCode ?? 0)"
        }
        let failures = entries.filter { ($0.exitCode ?? 0) != 0 }.count
        return failures == 0 ? "全部完成" : "\(failures) 条失败"
    }

    private var commandColor: Color {
        Color(red: 68 / 255, green: 78 / 255, blue: 100 / 255)
    }
}

private struct AgentCompletionRow: View {
    let entry: AgentTranscriptEntry

    var body: some View {
        VStack(spacing: 0) {
            if hasProgressDetails {
                AgentProgressSummaryRow(
                    progress: AgentRunProgress(
                        currentStep: entry.currentStep,
                        totalSteps: entry.totalSteps,
                        completedOperations: 0,
                        changedFiles: entry.changedFiles ?? 0,
                        addedLines: entry.addedLines ?? 0,
                        deletedLines: entry.deletedLines ?? 0
                    ),
                    isActive: false
                )
                Divider().opacity(0.22)
            }

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AeroTheme.deepLeaf)

                Text("已处理")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(AeroTheme.deepLeaf)

                Text(detailText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.faintText)

                Spacer()

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.faintText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(AeroTheme.leaf.opacity(0.055))
    }

    private var hasProgressDetails: Bool {
        entry.currentStep != nil
            || entry.totalSteps != nil
            || entry.changedFiles != nil
            || entry.addedLines != nil
            || entry.deletedLines != nil
    }

    private var detailText: String {
        var parts = [formattedDuration]
        if let inputTokens = entry.inputTokens {
            parts.append("输入 \(inputTokens.formatted())")
        }
        if let outputTokens = entry.outputTokens {
            parts.append("输出 \(outputTokens.formatted()) tokens")
        }
        return parts.joined(separator: " · ")
    }

    private var formattedDuration: String {
        let totalSeconds = max(0, (entry.durationMilliseconds ?? 0) / 1_000)
        if totalSeconds < 1 { return "不到 1 秒" }
        if totalSeconds < 60 { return "用时 \(totalSeconds) 秒" }
        return "用时 \(totalSeconds / 60) 分 \(totalSeconds % 60) 秒"
    }
}

private struct AgentProgressSummaryRow: View {
    let progress: AgentRunProgress
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.faintText)
                }
            }
            .frame(width: 14, height: 14)

            Text(stepText)
                .foregroundStyle(AeroTheme.secondaryText)

            Text("·")
                .foregroundStyle(AeroTheme.faintText.opacity(0.7))

            Text("\(progress.changedFiles) 个文件已更改")
                .foregroundStyle(AeroTheme.secondaryText)

            Spacer(minLength: 8)

            Text("+\(progress.addedLines)")
                .foregroundStyle(AeroTheme.deepLeaf)

            Text("-\(progress.deletedLines)")
                .foregroundStyle(AeroTheme.destructive)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(isActive ? 0.18 : 0.08))
    }

    private var stepText: String {
        if let currentStep = progress.currentStep,
           let totalSteps = progress.totalSteps {
            return "第 \(currentStep) / \(totalSteps) 步"
        }
        if progress.completedOperations > 0 {
            return isActive
                ? "已完成 \(progress.completedOperations) 项操作"
                : "完成 \(progress.completedOperations) 项操作"
        }
        return isActive ? "正在处理" : "处理完成"
    }
}

private struct AgentAttachmentChip: View {
    let attachment: AgentAttachmentRecord
    let onRemove: (() -> Void)?

    init(
        attachment: AgentAttachmentRecord,
        onRemove: (() -> Void)? = nil
    ) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 7) {
            attachmentPreview

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.text)
                    .lineLimit(1)
                if let byteSize = attachment.byteSize {
                    Text(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
                        .font(.system(size: 9))
                        .foregroundStyle(AeroTheme.faintText)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AeroTheme.secondaryText)
                .help("移除 \(attachment.displayName)")
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, onRemove == nil ? 9 : 4)
        .frame(height: 34)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AeroTheme.deepSky.opacity(0.16), lineWidth: 1)
        }
        .help(attachment.path)
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if attachment.isImage,
           let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: attachmentIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.deepSky)
                .frame(width: 26, height: 26)
                .background(AeroTheme.sky.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var attachmentIcon: String {
        guard let identifier = attachment.contentTypeIdentifier,
              let type = UTType(identifier) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
}

private struct AgentTaskRow: View {
    let entry: AgentTranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 140)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 7) {
                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(AeroTheme.faintText)

                    Text("你")
                        .foregroundStyle(AeroTheme.deepSky)

                    Image(systemName: "person.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(AeroTheme.deepSky)
                        .clipShape(Circle())
                }
                .font(.system(size: 10.5, weight: .bold))

                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.content)
                        .font(.system(size: 14))
                        .foregroundStyle(AeroTheme.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let attachments = entry.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 7) {
                                ForEach(attachments) { attachment in
                                    AgentAttachmentChip(attachment: attachment)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: 38)
                        .padding(.top, 3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: 680, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AeroTheme.userBubbleGradient)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AeroTheme.sky.opacity(0.1))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AeroTheme.deepSky.opacity(0.38), lineWidth: 1)
                }
                .shadow(color: AeroTheme.deepSky.opacity(0.13), radius: 9, y: 4)
            }
            .frame(maxWidth: 700, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AgentEventRow: View {
    let entry: AgentTranscriptEntry
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if entry.kind != .assistant {
                        Text(entry.title)
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundStyle(iconColor)
                    }
                    Spacer()
                    if let exitCode = entry.exitCode {
                        Text("exit \(exitCode)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(exitCode == 0 ? AeroTheme.deepLeaf : AeroTheme.destructive)
                    }

                    if isCollapsible {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AeroTheme.secondaryText)
                        .help(isExpanded ? "收起终端详情" : "展开终端详情")
                    }
                }

                Text(entry.content)
                    .font(contentFont)
                    .foregroundStyle(AeroTheme.text)
                    .lineSpacing(entry.kind == .assistant ? 4 : 2)
                    .textSelection(.enabled)
                    .lineLimit(entry.kind == .command && !isExpanded ? 1 : nil)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCollapsible, !isExpanded {
                    Text(outputSummary)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.faintText)
                }

                if let detail = entry.detail, !detail.isEmpty,
                   entry.kind != .command || isExpanded {
                    ScrollView([.horizontal, .vertical]) {
                        Text(detail)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(AeroTheme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: entry.kind == .command ? 280 : nil)
                    .scrollIndicators(.visible)
                    .padding(10)
                    .background(Color(red: 236 / 255, green: 247 / 255, blue: 250 / 255))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, entry.kind == .assistant ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private var icon: String {
        switch entry.kind {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .contextCompact: "arrow.triangle.2.circlepath"
        case .modelSwitch: "arrow.left.arrow.right.circle"
        case .completion: "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .user: AeroTheme.deepSky
        case .assistant: AeroTheme.deepLeaf
        case .command: Color(red: 68 / 255, green: 78 / 255, blue: 100 / 255)
        case .fileChange: Color(red: 14 / 255, green: 132 / 255, blue: 126 / 255)
        case .warning: Color(red: 174 / 255, green: 114 / 255, blue: 12 / 255)
        case .error: AeroTheme.destructive
        case .contextCompact: AeroTheme.deepSky
        case .modelSwitch: Color(red: 14 / 255, green: 132 / 255, blue: 126 / 255)
        case .completion: AeroTheme.deepLeaf
        }
    }

    private var rowBackground: Color {
        switch entry.kind {
        case .command:
            Color(red: 68 / 255, green: 78 / 255, blue: 100 / 255).opacity(0.035)
        case .fileChange:
            Color(red: 14 / 255, green: 132 / 255, blue: 126 / 255).opacity(0.035)
        case .warning:
            Color.yellow.opacity(0.045)
        case .error:
            AeroTheme.destructive.opacity(0.035)
        case .contextCompact:
            AeroTheme.sky.opacity(0.07)
        case .modelSwitch:
            AeroTheme.leaf.opacity(0.07)
        case .completion:
            AeroTheme.leaf.opacity(0.055)
        case .user, .assistant:
            Color.clear
        }
    }

    private var contentFont: Font {
        entry.kind == .command
            ? .system(size: 12, design: .monospaced)
            : .system(size: 13.5)
    }

    private var isCollapsible: Bool {
        entry.kind == .command && !(entry.detail?.isEmpty ?? true)
    }

    private var outputSummary: String {
        guard let detail = entry.detail else { return "无输出" }
        let lineCount = detail.split(separator: "\n", omittingEmptySubsequences: false).count
        let byteCount = detail.lengthOfBytes(using: .utf8)
        return "\(lineCount) 行输出 · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
    }
}

private struct AeroHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.28 : 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            }
    }
}
