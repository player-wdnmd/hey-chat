import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AgentWorkspaceView: View {
    let models: [AIModelConfiguration]
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @State private var isAttachmentDropTarget = false
    @State private var isRunReviewPresented = false
    @State private var isMemoryEditorPresented = false
    @State private var isLibraryPresented = false
    @State private var isInboxPresented = false
    @State private var isMaintenancePresented = false
    @State private var isContextInspectorPresented = false
    @State private var isWorkflowManagerPresented = false
    @State private var workflowAwaitingInput: AgentWorkflow?

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
        .alert(
            "运行记录操作失败",
            isPresented: Binding(
                get: { viewModel.runReviewError != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissRunReviewError() }
                }
            )
        ) {
            Button("好", role: .cancel) {
                viewModel.dismissRunReviewError()
            }
        } message: {
            Text(viewModel.runReviewError ?? "无法完成运行记录操作。")
        }
        .alert(
            "Agent 维护操作失败",
            isPresented: Binding(
                get: { viewModel.maintenanceError != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissMaintenanceError() }
                }
            )
        ) {
            Button("好", role: .cancel) { viewModel.dismissMaintenanceError() }
        } message: {
            Text(viewModel.maintenanceError ?? "无法完成维护操作。")
        }
        .sheet(isPresented: $isRunReviewPresented) {
            AgentRunReviewSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isMemoryEditorPresented) {
            AgentMemoryEditorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isLibraryPresented) {
            AgentLibrarySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isInboxPresented) {
            AgentInboxSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isMaintenancePresented) {
            AgentMaintenanceSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isContextInspectorPresented) {
            AgentContextInspectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isWorkflowManagerPresented) {
            AgentWorkflowManagerSheet(viewModel: viewModel)
        }
        .sheet(item: $workflowAwaitingInput) { workflow in
            AgentWorkflowInputSheet(workflow: workflow) { input in
                runWorkflow(workflow, input: input)
            }
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

            if viewModel.latestRun != nil {
                Button {
                    isRunReviewPresented = true
                } label: {
                    Label("审查", systemImage: "checklist")
                        .lineLimit(1)
                }
                .buttonStyle(AeroHeaderButtonStyle())
                .disabled(viewModel.isRunning)
                .help("查看本次 Agent 任务的文件变更与检查点")
            }

            Button {
                isMemoryEditorPresented = true
            } label: {
                Label("记忆", systemImage: "book.closed")
                    .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.workspaceURL == nil)
            .help("编辑项目长期记忆与个人执行偏好")

            Button {
                isLibraryPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "books.vertical")
                    Text("资料")
                    if !viewModel.referencedLibraryDocuments.isEmpty {
                        Text("\(viewModel.referencedLibraryDocuments.count)")
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.workspaceURL == nil)
            .help("管理项目资料库并引用到当前 Agent 会话")

            Button {
                isInboxPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full")
                    Text("收件箱")
                    if !viewModel.openInboxItems.isEmpty {
                        Text("\(viewModel.openInboxItems.count)")
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning)
            .help("记录临时任务并在之后分配给 Agent 项目")

            Button {
                isMaintenancePresented = true
            } label: {
                Label("维护", systemImage: "shield.lefthalf.filled")
                    .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.isMaintaining)
            .help("检查 Agent 本地数据状态，导出或恢复备份")

            Button {
                isContextInspectorPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.book.closed")
                    Text("上下文")
                    if !viewModel.contextManifests.isEmpty {
                        Text("\(viewModel.contextManifests.count)")
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.workspaceURL == nil)
            .help("查看 Agent 上下文交接记录")

            Menu {
                Section("常用") {
                    ForEach(viewModel.builtInWorkflows) { workflow in
                        workflowMenuButton(workflow)
                    }
                }
                if !viewModel.customWorkflows.isEmpty {
                    Section("本项目") {
                        ForEach(viewModel.customWorkflows) { workflow in
                            workflowMenuButton(workflow)
                        }
                    }
                }
                Divider()
                Button {
                    isWorkflowManagerPresented = true
                } label: {
                    Label("管理快捷工作流", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label("快捷", systemImage: "bolt.fill")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(AeroHeaderButtonStyle())
            .disabled(viewModel.isRunning || viewModel.workspaceURL == nil)
            .help("运行或管理 Agent 快捷工作流")

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

    private func workflowMenuButton(_ workflow: AgentWorkflow) -> some View {
        Button {
            if workflow.requiresInput {
                workflowAwaitingInput = workflow
            } else {
                runWorkflow(workflow)
            }
        } label: {
            Label(workflow.title, systemImage: workflow.iconName)
        }
        .disabled(selectedTarget == nil)
    }

    private func runWorkflow(_ workflow: AgentWorkflow, input: String = "") {
        guard let selectedTarget else { return }
        let prompt = workflow.renderedPrompt(input: input)
        guard !prompt.isEmpty else { return }
        viewModel.draft = ""
        viewModel.send(prompt, target: selectedTarget)
    }
}

private struct AgentWorkflowInputSheet: View {
    let workflow: AgentWorkflow
    let onRun: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(workflow.title, systemImage: workflow.iconName)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(AeroHeaderButtonStyle())
                .help("取消")
            }

            TextEditor(text: $input)
                .font(.system(size: 13.5))
                .foregroundStyle(AeroTheme.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(9)
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AeroTheme.deepSky.opacity(0.22), lineWidth: 1)
                }

            HStack {
                Spacer()
                Button("运行") {
                    onRun(input)
                    dismiss()
                }
                .buttonStyle(AeroPrimaryButtonStyle())
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(AeroTheme.mainBackground)
    }
}

private struct AgentLibrarySheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedDocumentID: UUID?
    @State private var documentPendingDelete: AgentLibraryDocument?

    private var documents: [AgentLibraryDocument] {
        viewModel.libraryDocuments.filter { $0.matches(searchText) }
    }

    private var selectedDocument: AgentLibraryDocument? {
        if let selectedDocumentID,
           let document = documents.first(where: { $0.id == selectedDocumentID }) {
            return document
        }
        return documents.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.32)
            HStack(spacing: 0) {
                documentList
                Divider().opacity(0.32)
                documentDetail
            }
        }
        .frame(width: 980, height: 650)
        .background(AeroTheme.mainBackground)
        .task {
            selectedDocumentID = viewModel.libraryDocuments.first?.id
        }
        .alert("移除这份资料？", isPresented: Binding(
            get: { documentPendingDelete != nil },
            set: { if !$0 { documentPendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { documentPendingDelete = nil }
            Button("移除", role: .destructive) {
                guard let document = documentPendingDelete else { return }
                viewModel.removeLibraryDocument(document.id)
                documentPendingDelete = nil
                selectedDocumentID = viewModel.libraryDocuments.first?.id
            }
        } message: {
            Text("仅移除 hey chat 的索引和引用，不会删除原始文件。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本地资料库")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
                Text("\(viewModel.workspaceURL?.lastPathComponent ?? "项目") · 原文件不复制")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.secondaryText)
            }
            Spacer()
            Button(action: chooseSources) {
                Label("添加资料", systemImage: "plus")
            }
            .buttonStyle(AeroPrimaryButtonStyle())
            Button("完成") { dismiss() }
                .buttonStyle(AeroHeaderButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(AeroTheme.glassGradient)
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            TextField("搜索已索引内容", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if documents.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(AeroTheme.deepSky.opacity(0.72))
                    Text(viewModel.libraryDocuments.isEmpty ? "尚未添加资料" : "没有匹配的资料")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedDocumentID) {
                    ForEach(documents) { document in
                        Button {
                            selectedDocumentID = document.id
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: document.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundStyle(document.isAvailable ? AeroTheme.deepSky : AeroTheme.faintText)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AeroTheme.text)
                                        .lineLimit(1)
                                    Text(document.isDirectory ? "\(document.indexedFileCount) 个已索引文件" : document.kindDisplayName)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(AeroTheme.faintText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if viewModel.referencedLibraryDocuments.contains(where: { $0.id == document.id }) {
                                    Image(systemName: "link.circle.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(AeroTheme.deepLeaf)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .tag(document.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 310)
        .background(Color.white.opacity(0.43))
    }

    @ViewBuilder
    private var documentDetail: some View {
        if let document = selectedDocument {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(document.displayName, systemImage: document.isDirectory ? "folder.fill" : "doc.text.fill")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(AeroTheme.text)
                            Text(document.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(AeroTheme.faintText)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Toggle("引用", isOn: Binding(
                            get: { viewModel.referencedLibraryDocuments.contains(where: { $0.id == document.id }) },
                            set: { viewModel.setLibraryDocumentReferenced(document.id, isReferenced: $0) }
                        ))
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(AeroTheme.secondaryText)
                    }
                    HStack(spacing: 14) {
                        metric("类型", document.kindDisplayName)
                        metric("索引", document.indexedAt.formatted(date: .abbreviated, time: .shortened))
                        metric("文本", "\(document.indexedText.count.formatted()) 字符")
                        if document.isDirectory { metric("文件", "\(document.indexedFileCount)") }
                        if !document.isAvailable { metric("状态", "原文件不可用") }
                    }
                    HStack {
                        Button {
                            viewModel.refreshLibraryDocument(document.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                        .disabled(!document.isAvailable)
                        .help("重新建立本地索引")
                        Button(role: .destructive) {
                            documentPendingDelete = document
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                        .help("移除资料引用")
                        Spacer()
                        Text("引用后会随下一次 Agent 请求传递来源和匹配摘录")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(AeroTheme.faintText)
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.55))
                Divider().opacity(0.26)
                ScrollView([.vertical, .horizontal]) {
                    Text(document.contextExcerpt(matching: searchText, maximumCharacters: 18_000))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AeroTheme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(18)
                }
                .background(Color(red: 240 / 255, green: 250 / 255, blue: 253 / 255))
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(AeroTheme.deepSky.opacity(0.72))
                Text("选择资料后可查看索引和引用状态")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(AeroTheme.faintText)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AeroTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.title = "添加本地资料"
        panel.prompt = "添加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = viewModel.workspaceURL
        guard panel.runModal() == .OK else { return }
        viewModel.addLibrarySources(panel.urls)
    }
}

private struct AgentInboxSheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: UUID?
    @State private var title = ""
    @State private var detail = ""

    private var selectedItem: AgentInboxItem? {
        if let selectedItemID,
           let item = viewModel.sortedInboxItems.first(where: { $0.id == selectedItemID }) { return item }
        return viewModel.sortedInboxItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("任务收件箱")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text("全局本机待办 · 可稍后归入项目")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)
            Divider().opacity(0.32)
            HStack(spacing: 0) {
                inboxList
                Divider().opacity(0.32)
                inboxDetail
            }
        }
        .frame(width: 900, height: 620)
        .background(AeroTheme.mainBackground)
        .task { selectedItemID = viewModel.sortedInboxItems.first?.id }
    }

    private var inboxList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("待办")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AeroTheme.secondaryText)
                Spacer()
                Button(action: newItem) {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(AeroHeaderButtonStyle())
                .help("新建收件箱任务")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider().opacity(0.25)
            List(selection: $selectedItemID) {
                ForEach(viewModel.sortedInboxItems) { item in
                    Button {
                        load(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.status == .completed ? AeroTheme.deepLeaf : AeroTheme.deepSky)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AeroTheme.text)
                                    .lineLimit(1)
                                Text(viewModel.projectDisplayName(for: item.projectID) ?? "未分配项目")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(AeroTheme.faintText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 300)
        .background(Color.white.opacity(0.43))
    }

    private var inboxDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                TextField("任务标题", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1) }
                Text("补充说明")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(AeroTheme.secondaryText)
                TextEditor(text: $detail)
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(9)
                    .background(Color.white.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1) }

                HStack {
                    Text("归属项目")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(AeroTheme.secondaryText)
                    Spacer()
                    Menu(viewModel.projectDisplayName(for: selectedItem?.projectID) ?? "未分配") {
                        Button("未分配") { assignSelected(to: nil) }
                        Divider()
                        ForEach(viewModel.sortedProjects) { project in
                            Button(project.displayName) { assignSelected(to: project.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(AeroHeaderButtonStyle())
                }

                HStack {
                    if let item = selectedItem {
                        Button {
                            viewModel.toggleInboxItem(item.id)
                        } label: {
                            Label(item.status == .completed ? "标为待处理" : "标为完成", systemImage: item.status == .completed ? "arrow.uturn.backward" : "checkmark")
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                        Button(role: .destructive) {
                            viewModel.deleteInboxItem(item.id)
                            newItem()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                        .help("删除任务")
                    }
                    Spacer()
                    if let item = selectedItem {
                        Button("交给 Agent") {
                            viewModel.saveInboxItem(itemWithCurrentText(item))
                            viewModel.prepareInboxItem(item.id)
                            dismiss()
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                    }
                    Button("保存") { save() }
                        .buttonStyle(AeroPrimaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
    }

    private func newItem() {
        selectedItemID = nil
        title = ""
        detail = ""
    }

    private func load(_ item: AgentInboxItem) {
        selectedItemID = item.id
        title = item.title
        detail = item.detail
    }

    private func itemWithCurrentText(_ item: AgentInboxItem) -> AgentInboxItem {
        var updated = item
        updated.title = title
        updated.detail = detail
        return updated
    }

    private func save() {
        let item = itemWithCurrentText(selectedItem ?? AgentInboxItem(title: title, detail: detail))
        viewModel.saveInboxItem(item)
        selectedItemID = item.id
    }

    private func assignSelected(to projectID: UUID?) {
        guard let item = selectedItem else { return }
        viewModel.saveInboxItem(itemWithCurrentText(item))
        viewModel.assignInboxItem(item.id, to: projectID)
    }
}

private struct AgentMaintenanceSheet: View {
    private enum Tab: Hashable {
        case health
        case backup
    }

    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .health
    @State private var restoreConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 维护")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text("本机健康检查、备份与恢复")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)
            Divider().opacity(0.32)

            Picker("维护页面", selection: $tab) {
                Text("健康").tag(Tab.health)
                Text("备份").tag(Tab.backup)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Group {
                switch tab {
                case .health: health
                case .backup: backup
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 560)
        .background(AeroTheme.mainBackground)
        .alert("恢复这份 Agent 备份？", isPresented: $restoreConfirmationPresented) {
            Button("取消", role: .cancel) { viewModel.cancelPendingBackupRestore() }
            Button("恢复", role: .destructive) {
                viewModel.confirmPendingBackupRestore()
            }
        } message: {
            Text("恢复前会自动创建当前 Agent 数据的保护备份。API Key 不会包含在导入或导出的内容中。\n\n\(viewModel.pendingBackupRestoreSummary ?? "")")
        }
    }

    private var health: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text("本机状态")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(AeroTheme.secondaryText)
                ForEach(viewModel.healthChecks) { check in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: check.severity.systemImage)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(healthColor(check.severity))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.title)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(AeroTheme.text)
                            Text(check.detail)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AeroTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(13)
                    .background(Color.white.opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(healthColor(check.severity).opacity(0.15), lineWidth: 1)
                    }
                }
            }
            .padding(22)
        }
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("导出 Agent 备份", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
                Text("导出 Agent 项目、会话、运行记录、记忆、资料索引、快捷工作流、Inbox 和个人执行偏好。原始资料文件及 API Key 均不会写入备份。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导出备份") { viewModel.exportBackup() }
                        .buttonStyle(AeroPrimaryButtonStyle())
                    if let url = viewModel.lastBackupURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AeroTheme.faintText)
                            .lineLimit(1)
                    }
                }
            }
            .padding(17)
            .background(Color.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Label("恢复 Agent 备份", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
                Text("选择此前导出的 `.heychat-agent-backup` 文件。确认恢复时，当前数据会先保存一份自动保护备份。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("选择并恢复备份") {
                    if viewModel.chooseBackupForRestore() {
                        restoreConfirmationPresented = true
                    }
                }
                .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(17)
            .background(Color.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()
        }
        .padding(22)
    }

    private func healthColor(_ severity: AgentHealthSeverity) -> Color {
        switch severity {
        case .healthy: AeroTheme.deepLeaf
        case .notice: AeroTheme.deepSky
        case .warning: Color.orange
        }
    }
}

private struct AgentWorkflowManagerSheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var title = ""
    @State private var iconName = "bolt.fill"
    @State private var promptTemplate = ""
    @State private var requiresInput = false
    @State private var workflowPendingDelete: AgentWorkflow?

    private let icons = [
        "bolt.fill",
        "terminal",
        "hammer.fill",
        "stethoscope",
        "wrench.and.screwdriver.fill",
        "text.append",
        "folder.badge.gearshape",
        "checkmark.seal.fill",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("快捷工作流")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text(viewModel.workspaceURL?.lastPathComponent ?? "项目")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)

            Divider().opacity(0.34)

            HStack(spacing: 0) {
                workflowList
                Divider().opacity(0.34)
                editor
            }
        }
        .frame(width: 920, height: 620)
        .background(AeroTheme.mainBackground)
        .task {
            if editingID == nil, let first = viewModel.customWorkflows.first {
                load(first)
            } else if editingID == nil {
                newWorkflow()
            }
        }
        .alert("删除此快捷工作流？", isPresented: Binding(
            get: { workflowPendingDelete != nil },
            set: { isPresented in
                if !isPresented { workflowPendingDelete = nil }
            }
        )) {
            Button("取消", role: .cancel) { workflowPendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let workflow = workflowPendingDelete else { return }
                viewModel.deleteWorkflow(workflow.id)
                workflowPendingDelete = nil
                newWorkflow()
            }
        } message: {
            Text("删除后该项目将不再显示此快捷工作流。")
        }
    }

    private var workflowList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本项目")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AeroTheme.secondaryText)
                Spacer()
                Button(action: newWorkflow) {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(AeroHeaderButtonStyle())
                .help("新增快捷工作流")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider().opacity(0.25)

            List(selection: $editingID) {
                ForEach(viewModel.customWorkflows) { workflow in
                    Button {
                        load(workflow)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: workflow.iconName)
                                .foregroundStyle(AeroTheme.deepSky)
                            Text(workflow.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(AeroTheme.text)
                                .lineLimit(1)
                            Spacer()
                            if workflow.requiresInput {
                                Image(systemName: "text.cursor")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(AeroTheme.faintText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(workflow.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 260)
        .background(Color.white.opacity(0.42))
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(icons, id: \.self) { icon in
                            Button {
                                iconName = icon
                            } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    } label: {
                        Image(systemName: iconName)
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 42, height: 38)
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(AeroHeaderButtonStyle())
                    .help("选择图标")

                    TextField("工作流名称", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AeroTheme.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.74))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
                        }
                }

                Toggle("运行前补充描述", isOn: $requiresInput)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AeroTheme.secondaryText)

                Text("任务模板")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(AeroTheme.secondaryText)
                TextEditor(text: $promptTemplate)
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280)
                    .padding(9)
                    .background(Color.white.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
                    }

                HStack {
                    if editingID != nil {
                        Button(role: .destructive) {
                            workflowPendingDelete = selectedWorkflow
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(AeroHeaderButtonStyle())
                        .help("删除此快捷工作流")
                    }
                    Spacer()
                    Button("保存") {
                        saveWorkflow()
                    }
                    .buttonStyle(AeroPrimaryButtonStyle())
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedWorkflow: AgentWorkflow? {
        guard let editingID else { return nil }
        return viewModel.customWorkflows.first(where: { $0.id == editingID })
    }

    private func newWorkflow() {
        editingID = nil
        title = ""
        iconName = "bolt.fill"
        promptTemplate = ""
        requiresInput = false
    }

    private func load(_ workflow: AgentWorkflow) {
        editingID = workflow.id
        title = workflow.title
        iconName = workflow.iconName
        promptTemplate = workflow.promptTemplate
        requiresInput = workflow.requiresInput
    }

    private func saveWorkflow() {
        let workflow = AgentWorkflow(
            id: editingID ?? UUID(),
            title: title,
            iconName: iconName,
            promptTemplate: promptTemplate,
            requiresInput: requiresInput
        )
        viewModel.saveWorkflow(workflow)
        load(workflow)
    }
}

private struct AgentContextInspectorSheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedManifestID: UUID?

    private var manifests: [AgentHandoffManifest] {
        viewModel.contextManifests
    }

    private var selectedManifest: AgentHandoffManifest? {
        if let selectedManifestID,
           let manifest = manifests.first(where: { $0.id == selectedManifestID }) {
            return manifest
        }
        return manifests.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("上下文交接")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text(contextStatusText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)

            Divider().opacity(0.35)

            if manifests.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    manifestList
                    Divider().opacity(0.35)
                    manifestDetail
                }
            }
        }
        .frame(width: 1_020, height: 680)
        .background(AeroTheme.mainBackground)
        .task {
            selectedManifestID = selectedManifestID ?? manifests.first?.id
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AeroTheme.deepSky)
            Text("当前会话尚未生成交接记录")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AeroTheme.text)
            if viewModel.currentContextSummary != nil {
                Text("已恢复的旧会话会在下一次模型切换、上下文压缩或 CLI 恢复时生成 Manifest。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AeroTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var manifestList: some View {
        List(selection: $selectedManifestID) {
            ForEach(manifests) { manifest in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: manifest.kind.systemImage)
                            .foregroundStyle(kindColor(manifest.kind))
                        Text(manifest.kind.displayName)
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundStyle(kindColor(manifest.kind))
                        Spacer()
                        deliveryBadge(manifest)
                    }
                    Text(manifest.reason)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text("第 \(manifest.generation) 代")
                        Text("·")
                        Text("\(manifest.estimatedTokens.formatted()) tokens")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AeroTheme.faintText)
                }
                .padding(.vertical, 5)
                .tag(manifest.id)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 292)
        .scrollContentBackground(.hidden)
        .background(Color.white.opacity(0.48))
    }

    @ViewBuilder
    private var manifestDetail: some View {
        if let manifest = selectedManifest {
            VStack(alignment: .leading, spacing: 0) {
                manifestSummary(manifest)
                Divider().opacity(0.3)
                HStack {
                    Text("Manifest 正文")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.secondaryText)
                    Spacer()
                    Text("v\(manifest.schemaVersion)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AeroTheme.faintText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                Divider().opacity(0.22)
                ScrollView([.vertical, .horizontal]) {
                    Text(manifest.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AeroTheme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(16)
                }
                .background(Color(red: 239 / 255, green: 249 / 255, blue: 252 / 255))
            }
        } else {
            Color.clear
        }
    }

    private func manifestSummary(_ manifest: AgentHandoffManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(manifest.kind.displayName, systemImage: manifest.kind.systemImage)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(kindColor(manifest.kind))
                    Text(manifest.reason)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(2)
                }
                Spacer()
                deliveryStatus(manifest)
            }

            HStack(spacing: 14) {
                metric("代次", value: "\(manifest.generation)")
                metric("来源", value: "\(manifest.sourceEntryCount) 条")
                metric("估算", value: "\(manifest.estimatedTokens.formatted()) tokens")
                if let model = manifest.destinationModelName {
                    metric("目标", value: model)
                }
            }

            HStack(spacing: 9) {
                Text("生成于 \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                if let deliveredAt = manifest.deliveredAt {
                    Text("已传递于 \(deliveredAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AeroTheme.faintText)
        }
        .padding(18)
        .background(Color.white.opacity(0.57))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(AeroTheme.faintText)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AeroTheme.secondaryText)
                .lineLimit(1)
        }
    }

    private func deliveryBadge(_ manifest: AgentHandoffManifest) -> some View {
        Image(systemName: manifest.isDelivered ? "checkmark.circle.fill" : "clock.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(manifest.isDelivered ? AeroTheme.deepLeaf : AeroTheme.deepSky)
    }

    private func deliveryStatus(_ manifest: AgentHandoffManifest) -> some View {
        Label(
            manifest.isDelivered ? "已传递" : "待传递",
            systemImage: manifest.isDelivered ? "checkmark.circle.fill" : "clock.fill"
        )
        .font(.system(size: 10.5, weight: .heavy))
        .foregroundStyle(manifest.isDelivered ? AeroTheme.deepLeaf : AeroTheme.deepSky)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background((manifest.isDelivered ? AeroTheme.deepLeaf : AeroTheme.deepSky).opacity(0.12))
        .clipShape(Capsule())
    }

    private func kindColor(_ kind: AgentHandoffKind) -> Color {
        switch kind {
        case .compaction: AeroTheme.deepSky
        case .modelSwitch: AeroTheme.deepLeaf
        case .recovery: AeroTheme.secondaryText
        }
    }

    private var contextStatusText: String {
        if viewModel.isContextHandoffPending { return "当前交接待新 Agent 线程接收" }
        if manifests.isEmpty { return "会话可见历史保持完整" }
        return "已保留 \(manifests.count) 份版本化交接记录"
    }
}

private struct AgentMemoryEditorSheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var projectMemory: AgentProjectMemory
    @State private var personalPreferences: AgentPersonalPreferences

    init(viewModel: AgentWorkspaceViewModel) {
        self.viewModel = viewModel
        _projectMemory = State(initialValue: viewModel.projectMemory)
        _personalPreferences = State(initialValue: viewModel.personalPreferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 记忆")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text("\(viewModel.workspaceURL?.lastPathComponent ?? "项目") · 本机保存")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
                Button("保存") {
                    viewModel.saveMemory(
                        projectMemory: projectMemory,
                        personalPreferences: personalPreferences
                    )
                    dismiss()
                }
                .buttonStyle(AeroPrimaryButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memorySection(
                        title: "项目长期记忆",
                        isEnabled: $projectMemory.isEnabled
                    ) {
                        memoryTextField("项目目标", text: $projectMemory.projectGoal)
                        memoryEditor("技术栈与架构", text: $projectMemory.technicalContext, minimumHeight: 76)
                        memoryEditor("常用命令", text: $projectMemory.commonCommands, minimumHeight: 64)
                        memoryEditor("代码规范", text: $projectMemory.conventions, minimumHeight: 76)
                        memoryEditor("约束与注意事项", text: $projectMemory.constraints, minimumHeight: 76)
                        memoryEditor("已知问题与后续事项", text: $projectMemory.knownIssues, minimumHeight: 76)
                    }

                    memorySection(
                        title: "个人执行偏好",
                        isEnabled: $personalPreferences.isEnabled
                    ) {
                        memoryEditor("个人偏好", text: $personalPreferences.content, minimumHeight: 132)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AeroTheme.mainBackground)
        }
        .frame(width: 760, height: 720)
    }

    private func memorySection<Content: View>(
        title: String,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
                Spacer()
                Toggle("启用", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("在后续 Agent 请求中使用此记忆")
            }
            content()
                .opacity(isEnabled.wrappedValue ? 1 : 0.5)
                .disabled(!isEnabled.wrappedValue)
        }
        .padding(18)
        .aeroGlass(cornerRadius: 14)
    }

    private func memoryTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundStyle(AeroTheme.secondaryText)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(AeroTheme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private func memoryEditor(
        _ title: String,
        text: Binding<String>,
        minimumHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundStyle(AeroTheme.secondaryText)
            TextEditor(text: text)
                .font(.system(size: 12.5))
                .foregroundStyle(AeroTheme.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
                }
        }
    }
}

private struct AgentRunReviewSheet: View {
    @ObservedObject var viewModel: AgentWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRunID: UUID?
    @State private var selectedFileID: UUID?
    @State private var isRestoreConfirmationPresented = false

    private var runs: [AgentRunRecord] { viewModel.runRecords }

    private var selectedRun: AgentRunRecord? {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) { return run }
        return runs.first
    }

    private var selectedFile: AgentRunFileChange? {
        guard let selectedRun else { return nil }
        if let selectedFileID, let file = selectedRun.files.first(where: { $0.id == selectedFileID }) {
            return file
        }
        return selectedRun.files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("任务审查")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(AeroTheme.text)
                    Text("本轮 Agent 的变更、模型来源和可恢复检查点")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AeroHeaderButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(AeroTheme.glassGradient)

            Divider().opacity(0.35)

            if runs.isEmpty {
                ContentUnavailableView(
                    "暂无 Agent 运行记录",
                    systemImage: "checklist",
                    description: Text("完成一次 Agent 任务后，可在这里审查文件变更。")
                )
            } else {
                HStack(spacing: 0) {
                    runList
                    Divider().opacity(0.35)
                    detailPane
                }
            }
        }
        .frame(width: 1_040, height: 680)
        .background(AeroTheme.mainBackground)
        .task {
            selectedRunID = selectedRunID ?? runs.first?.id
            selectedFileID = selectedFileID ?? selectedRun?.files.first?.id
        }
        .onChange(of: selectedRunID) { _, _ in
            selectedFileID = selectedRun?.files.first?.id
        }
        .alert("恢复本次 Agent 修改？", isPresented: $isRestoreConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                if let run = selectedRun { viewModel.restoreRun(run.id) }
            }
        } message: {
            Text("将恢复到本次 Agent 运行开始前的状态。任务结束后的额外人工修改会阻止恢复，不会被静默覆盖。")
        }
    }

    private var runList: some View {
        List(selection: $selectedRunID) {
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon(run.status))
                            .foregroundStyle(statusColor(run.status))
                        Text(run.status.displayName)
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundStyle(statusColor(run.status))
                        Spacer()
                        Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AeroTheme.faintText)
                    }
                    Text(run.taskSummary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(2)
                    Text("\(run.modelName) · \(run.files.count) 个文件 · +\(run.additions) -\(run.deletions)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AeroTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.vertical, 5)
                .tag(run.id)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 292)
        .scrollContentBackground(.hidden)
        .background(Color.white.opacity(0.48))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let run = selectedRun {
            VStack(alignment: .leading, spacing: 0) {
                runSummary(run)
                Divider().opacity(0.32)
                HStack(spacing: 0) {
                    fileList(run)
                    Divider().opacity(0.32)
                    patchPane(run)
                }
            }
        } else {
            Color.clear
        }
    }

    private func runSummary(_ run: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.taskSummary)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(2)
                    Text("\(run.channelName) · \(run.modelName) · \(run.engine.channelDisplayName) CLI")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                Spacer(minLength: 16)
                statusPill(run.status)
            }

            HStack(spacing: 13) {
                Label("\(run.files.count) 个文件", systemImage: "doc.text")
                Text("+\(run.additions)").foregroundStyle(AeroTheme.deepLeaf)
                Text("-\(run.deletions)").foregroundStyle(AeroTheme.destructive)
                if let completedAt = run.completedAt {
                    Text("完成于 \(completedAt.formatted(date: .omitted, time: .shortened))")
                }
                Spacer()
                if run.checkpoint != nil, !run.checkpoint!.isRestored {
                    Button {
                        isRestoreConfirmationPresented = true
                    } label: {
                        Label(viewModel.isRestoringRun ? "正在恢复" : "恢复到运行前", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(AeroHeaderButtonStyle())
                    .disabled(viewModel.isRestoringRun || run.status == .running)
                    .help("仅在工作区没有后续人工修改时可恢复")
                } else if run.checkpoint?.isRestored == true {
                    Label("已恢复", systemImage: "checkmark.circle")
                        .foregroundStyle(AeroTheme.deepLeaf)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(AeroTheme.faintText)

            if let reason = run.checkpointUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.57))
    }

    private func fileList(_ run: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文件")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(AeroTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            Divider().opacity(0.25)
            if run.files.isEmpty {
                Text("没有检测到文件变更")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AeroTheme.faintText)
                    .padding(14)
                Spacer()
            } else {
                List(selection: $selectedFileID) {
                    ForEach(run.files) { file in
                        HStack(spacing: 7) {
                            Image(systemName: fileIcon(file.kind))
                                .foregroundStyle(fileColor(file.kind))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.path)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AeroTheme.text)
                                    .lineLimit(2)
                                Text(file.kind.displayName)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(fileColor(file.kind))
                            }
                            Spacer(minLength: 2)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("+\(file.additions)").foregroundStyle(AeroTheme.deepLeaf)
                                Text("-\(file.deletions)").foregroundStyle(AeroTheme.destructive)
                            }
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .padding(.vertical, 3)
                        .tag(file.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 264)
        .background(Color.white.opacity(0.34))
    }

    private func patchPane(_ run: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedFile?.path ?? "变更详情")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Text("\(run.files.count) 项")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AeroTheme.faintText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider().opacity(0.25)

            if let patch = selectedFile?.patch, !patch.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(patch)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AeroTheme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(14)
                }
                .background(Color(red: 239 / 255, green: 249 / 255, blue: 252 / 255))
            } else {
                VStack(spacing: 9) {
                    Image(systemName: selectedFile?.kind == .binary ? "doc.fill" : "doc.text")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(AeroTheme.faintText)
                    Text(selectedFile?.kind == .binary ? "二进制文件不提供文本补丁" : "选择文件查看补丁")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.45))
    }

    private func statusPill(_ status: AgentRunStatus) -> some View {
        Label(status.displayName, systemImage: statusIcon(status))
            .font(.system(size: 10.5, weight: .heavy))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusIcon(_ status: AgentRunStatus) -> String {
        switch status {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        }
    }

    private func statusColor(_ status: AgentRunStatus) -> Color {
        switch status {
        case .running: AeroTheme.deepSky
        case .completed, .restored: AeroTheme.deepLeaf
        case .failed: AeroTheme.destructive
        case .cancelled: AeroTheme.secondaryText
        }
    }

    private func fileIcon(_ kind: AgentRunFileChangeKind) -> String {
        switch kind {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .binary: "doc.fill"
        }
    }

    private func fileColor(_ kind: AgentRunFileChangeKind) -> Color {
        switch kind {
        case .added: AeroTheme.deepLeaf
        case .modified: AeroTheme.deepSky
        case .deleted: AeroTheme.destructive
        case .binary: AeroTheme.secondaryText
        }
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
    case recovery

    var manifestKind: AgentHandoffKind {
        switch self {
        case .compaction: .compaction
        case .modelSwitch: .modelSwitch
        case .recovery: .recovery
        }
    }
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
    @Published private(set) var runReviewError: String?
    @Published private(set) var maintenanceError: String?
    @Published private(set) var isMaintaining = false
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var pendingBackupRestoreSummary: String?
    @Published private(set) var isRestoringRun = false
    @Published private(set) var selectedTargetID = ""
    @Published private(set) var reasoningEffortOverrides: [String: AgentReasoningEffort] = [:]
    @Published private(set) var runProgress = AgentRunProgress()
    @Published private(set) var draftAttachments: [AgentAttachmentRecord] = []
    @Published private(set) var personalPreferences = AgentPersonalPreferences()
    @Published private(set) var inboxItems: [AgentInboxItem] = []
    @Published var draft = ""

    private let provider = AgentProviderRouter()
    private let historyStore: AgentHistoryStore
    private let maintenanceStore: AgentMaintenanceStore
    private let checkpointStore = AgentRunCheckpointStore()
    private let personalPreferencesStore = AgentPersonalPreferencesStore()
    private var runTask: Task<Void, Never>?
    private var activeTargetID: String?
    private var contextSummary: String?
    private var contextHandoffPending = false
    private var lastCompactedAt: Date?
    private var compactedEntryCount = 0
    private var contextGeneration = 0
    private var lastInputTokens: Int?
    private var handoffManifests: [AgentHandoffManifest] = []
    private var referencedLibraryDocumentIDs: [UUID] = []
    private var pendingBackupRestore: AgentBackupPayload?
    private var runStartedAt: Date?
    private var runCompletionRecorded = false
    private var runBaselineSnapshot = AgentWorkspaceChangeSnapshot()
    private var runTouchedPaths: Set<String> = []
    private var activeRunID: UUID?
    private var didRestoreHistory = false
    private var codexAvailable: Bool?
    private var claudeAvailable: Bool?
    private var grokAvailable: Bool?
    private let legacyWorkspaceDefaultsKey = "agent.workspace.path"
    private let legacyWritableDirectoriesDefaultsKey = "agent.additional-writable-paths"
    private let selectedTargetDefaultsKey = "agent.selected-target-id"
    private let reasoningEffortDefaultsKey = "agent.reasoning-effort-overrides"

    init() {
        let historyStore = AgentHistoryStore()
        self.historyStore = historyStore
        self.maintenanceStore = AgentMaintenanceStore(historyStore: historyStore)
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
        personalPreferences = personalPreferencesStore.load()
    }

    func restoreWorkspace() {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true

        do {
            let archive = try historyStore.load()
            projects = archive.projects
            inboxItems = archive.inbox
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

    var latestRun: AgentRunRecord? {
        currentSession?.runRecords.max(by: { $0.startedAt < $1.startedAt })
    }

    var runRecords: [AgentRunRecord] {
        (currentSession?.runRecords ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    var contextManifests: [AgentHandoffManifest] {
        handoffManifests.sorted { $0.createdAt > $1.createdAt }
    }

    var currentContextSummary: String? {
        contextSummary
    }

    var isContextHandoffPending: Bool {
        contextHandoffPending
    }

    var projectMemory: AgentProjectMemory {
        currentProject?.memory ?? AgentProjectMemory()
    }

    var builtInWorkflows: [AgentWorkflow] {
        AgentWorkflow.builtInWorkflows()
    }

    var customWorkflows: [AgentWorkflow] {
        currentProject?.customWorkflows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        } ?? []
    }

    var libraryDocuments: [AgentLibraryDocument] {
        currentProject?.localLibrary.sorted {
            if $0.indexedAt != $1.indexedAt { return $0.indexedAt > $1.indexedAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        } ?? []
    }

    var referencedLibraryDocuments: [AgentLibraryDocument] {
        let byID = Dictionary(uniqueKeysWithValues: libraryDocuments.map { ($0.id, $0) })
        return referencedLibraryDocumentIDs.compactMap { byID[$0] }
    }

    var sortedInboxItems: [AgentInboxItem] {
        inboxItems.sorted {
            if $0.status != $1.status { return $0.status == .open }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var openInboxItems: [AgentInboxItem] {
        inboxItems.filter { $0.status == .open }
    }

    var healthChecks: [AgentHealthCheck] {
        maintenanceStore.healthChecks(for: currentArchive)
    }

    func addLibrarySources(_ urls: [URL]) {
        guard !isRunning,
              let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let existing = projects[projectIndex].localLibrary
        statusText = "正在建立资料索引"
        Task { [weak self] in
            let indexed = await Task.detached(priority: .utility) {
                urls.compactMap { url -> AgentLibraryDocument? in
                    let standardizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                    let existingID = existing.first(where: { $0.path == standardizedPath })?.id
                    return try? AgentLibraryIndexer.index(url: url, existingID: existingID)
                }
            }.value
            guard let self,
                  let index = self.projects.firstIndex(where: { $0.id == projectID }) else { return }
            var documents = self.projects[index].libraryDocuments ?? []
            for document in indexed {
                if let existingIndex = documents.firstIndex(where: { $0.id == document.id || $0.path == document.path }) {
                    documents[existingIndex] = document
                } else {
                    documents.append(document)
                }
            }
            self.projects[index].libraryDocuments = documents.isEmpty ? nil : documents
            self.projects[index].updatedAt = .now
            self.statusText = indexed.isEmpty ? "未能建立资料索引" : "已索引 \(indexed.count) 份资料"
            self.persistHistory()
        }
    }

    func refreshLibraryDocument(_ documentID: UUID) {
        guard !isRunning,
              let document = libraryDocuments.first(where: { $0.id == documentID }) else { return }
        addLibrarySources([document.url])
    }

    func removeLibraryDocument(_ documentID: UUID) {
        guard !isRunning,
              let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var documents = projects[projectIndex].libraryDocuments ?? []
        documents.removeAll { $0.id == documentID }
        projects[projectIndex].libraryDocuments = documents.isEmpty ? nil : documents
        referencedLibraryDocumentIDs.removeAll { $0 == documentID }
        projects[projectIndex].updatedAt = .now
        statusText = "已移除资料引用"
        updateCurrentSession()
    }

    func setLibraryDocumentReferenced(_ documentID: UUID, isReferenced: Bool) {
        guard !isRunning, libraryDocuments.contains(where: { $0.id == documentID }) else { return }
        if isReferenced {
            if !referencedLibraryDocumentIDs.contains(documentID) {
                referencedLibraryDocumentIDs.append(documentID)
            }
        } else {
            referencedLibraryDocumentIDs.removeAll { $0 == documentID }
        }
        statusText = isReferenced ? "资料已引用到当前会话" : "已取消资料引用"
        updateCurrentSession()
    }

    func saveInboxItem(_ item: AgentInboxItem) {
        guard !isRunning else { return }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var updated = item
        updated.title = title
        updated.detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.updatedAt = .now
        if let index = inboxItems.firstIndex(where: { $0.id == item.id }) {
            updated.createdAt = inboxItems[index].createdAt
            inboxItems[index] = updated
        } else {
            inboxItems.append(updated)
        }
        statusText = "任务已保存到收件箱"
        persistHistory()
    }

    func deleteInboxItem(_ itemID: UUID) {
        guard !isRunning else { return }
        inboxItems.removeAll { $0.id == itemID }
        statusText = "已删除收件箱任务"
        persistHistory()
    }

    func toggleInboxItem(_ itemID: UUID) {
        guard !isRunning, let index = inboxItems.firstIndex(where: { $0.id == itemID }) else { return }
        inboxItems[index].status = inboxItems[index].status == .open ? .completed : .open
        inboxItems[index].updatedAt = .now
        persistHistory()
    }

    func assignInboxItem(_ itemID: UUID, to projectID: UUID?) {
        guard !isRunning, let index = inboxItems.firstIndex(where: { $0.id == itemID }) else { return }
        inboxItems[index].projectID = projectID
        inboxItems[index].updatedAt = .now
        statusText = projectID == nil ? "任务已移出项目" : "任务已分配到项目"
        persistHistory()
    }

    func prepareInboxItem(_ itemID: UUID) {
        guard !isRunning, let item = inboxItems.first(where: { $0.id == itemID }) else { return }
        if let projectID = item.projectID, projectID != selectedProjectID {
            selectProject(projectID)
        }
        draft = [item.title, item.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        statusText = "已写入 Agent 输入框"
    }

    func saveWorkflow(_ workflow: AgentWorkflow) {
        let title = workflow.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = workflow.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning,
              !title.isEmpty,
              !prompt.isEmpty,
              let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        var updated = workflow
        updated.title = title
        updated.promptTemplate = prompt
        updated.updatedAt = .now
        var workflows = projects[projectIndex].workflows ?? []
        if let existingIndex = workflows.firstIndex(where: { $0.id == workflow.id }) {
            updated.createdAt = workflows[existingIndex].createdAt
            workflows[existingIndex] = updated
        } else {
            workflows.append(updated)
        }
        projects[projectIndex].workflows = workflows
        projects[projectIndex].updatedAt = .now
        persistHistory()
        statusText = "快捷工作流已保存"
    }

    func deleteWorkflow(_ workflowID: UUID) {
        guard !isRunning,
              let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        var workflows = projects[projectIndex].workflows ?? []
        workflows.removeAll { $0.id == workflowID }
        projects[projectIndex].workflows = workflows.isEmpty ? nil : workflows
        projects[projectIndex].updatedAt = .now
        persistHistory()
        statusText = "快捷工作流已删除"
    }

    func saveMemory(
        projectMemory: AgentProjectMemory,
        personalPreferences: AgentPersonalPreferences
    ) {
        guard !isRunning,
              let projectID = selectedProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        var updatedMemory = projectMemory
        updatedMemory.updatedAt = .now
        var updatedPreferences = personalPreferences
        updatedPreferences.updatedAt = .now
        projects[projectIndex].memory = updatedMemory
        projects[projectIndex].updatedAt = .now
        self.personalPreferences = updatedPreferences
        personalPreferencesStore.save(updatedPreferences)
        persistHistory()
        statusText = "项目记忆已保存"
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
            let sourceTargetID = activeTargetID
            activeTargetID = target.id
            let plan = AgentContextCompactor.recoveryPlan(
                entries: entries,
                projectPath: workspaceURL.path,
                reason: "已切换到 \(target.title)"
            )
            applyContextHandoff(
                plan,
                event: .modelSwitch(target.title),
                sourceTargetID: sourceTargetID,
                destinationTarget: target
            )
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

    func dismissRunReviewError() {
        runReviewError = nil
    }

    func dismissMaintenanceError() {
        maintenanceError = nil
    }

    func exportBackup() {
        guard !isRunning, !isMaintaining else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Agent 备份"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "hey-chat-agent-backup.heychat-agent-backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isMaintaining = true
        defer { isMaintaining = false }
        do {
            try maintenanceStore.writeBackup(
                AgentBackupPayload(
                    archive: currentArchive,
                    personalPreferences: personalPreferences
                ),
                to: url
            )
            lastBackupURL = url
            statusText = "Agent 备份已导出"
        } catch {
            maintenanceError = error.localizedDescription
        }
    }

    func chooseBackupForRestore() -> Bool {
        guard !isRunning, !isMaintaining else { return false }
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 备份"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let payload = try maintenanceStore.readBackup(from: url)
            pendingBackupRestore = payload
            pendingBackupRestoreSummary = "备份创建于 \(payload.createdAt.formatted(date: .abbreviated, time: .shortened))，包含 \(payload.archive.projects.count) 个项目和 \(payload.archive.inbox.count) 项收件箱任务。"
            return true
        } catch {
            maintenanceError = error.localizedDescription
            return false
        }
    }

    func cancelPendingBackupRestore() {
        pendingBackupRestore = nil
        pendingBackupRestoreSummary = nil
    }

    func confirmPendingBackupRestore() {
        guard !isRunning, !isMaintaining, let payload = pendingBackupRestore else { return }
        isMaintaining = true
        defer {
            isMaintaining = false
            cancelPendingBackupRestore()
        }
        do {
            let safetyBackupURL = try maintenanceStore.createAutomaticBackup(
                archive: currentArchive,
                personalPreferences: personalPreferences
            )
            try historyStore.save(payload.archive)
            personalPreferencesStore.save(payload.personalPreferences)
            projects = []
            inboxItems = []
            personalPreferences = payload.personalPreferences
            didRestoreHistory = false
            clearWorkspaceSelection()
            restoreWorkspace()
            lastBackupURL = safetyBackupURL
            statusText = "已恢复 Agent 备份；恢复前数据已自动备份"
        } catch {
            maintenanceError = error.localizedDescription
        }
    }

    func restoreRun(_ runID: UUID) {
        guard !isRunning, !isRestoringRun,
              let workspaceURL,
              let run = currentSession?.runRecords.first(where: { $0.id == runID }) else {
            return
        }
        isRestoringRun = true
        statusText = "正在恢复检查点"
        let checkpointStore = checkpointStore
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try checkpointStore.restore(run, workspaceURL: workspaceURL)
                }
            }.value
            guard let self else { return }
            self.isRestoringRun = false
            switch result {
            case .success(let restoredRun):
                self.replaceRun(restoredRun)
                self.statusText = "已恢复到 Agent 运行前"
                self.persistHistory()
            case .failure(let error):
                self.statusText = "恢复未执行"
                self.runReviewError = error.localizedDescription
            }
        }
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
            applyContextHandoff(plan, event: .recovery)
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
        activeRunID = nil
        statusText = "正在启动 Agent"
        updateCurrentSession()

        let writableURLs = additionalWritableURLs
        let activeThreadID = threadID
        let projectMemoryContext = self.projectMemory.context
        let personalPreferencesContext = self.personalPreferences.context
        let libraryContext = self.libraryContext(matching: displayPrompt)
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
                let checkpointStore = checkpointStore
                let runRecord = await Task.detached(priority: .utility) {
                    checkpointStore.beginRun(
                        workspaceURL: workspaceURL,
                        taskSummary: displayPrompt,
                        target: target
                    )
                }.value
                registerRun(runRecord)
                try Task.checkCancellation()
                let request = AgentRunRequest(
                    prompt: displayPrompt,
                    attachments: stagedAttachments.attachments,
                    workspaceURL: workspaceURL,
                    additionalWritableURLs: writableURLs
                        + [stagedAttachments.directoryURL].compactMap { $0 },
                    target: target,
                    threadID: activeThreadID,
                    projectMemory: projectMemoryContext,
                    personalPreferences: personalPreferencesContext,
                    libraryContext: libraryContext,
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
                    applyContextHandoff(recoveryPlan, event: .recovery)
                    statusText = "正在接续新的 Agent 会话"
                    let retryRequest = AgentRunRequest(
                        prompt: displayPrompt,
                        attachments: stagedAttachments.attachments,
                        workspaceURL: workspaceURL,
                        additionalWritableURLs: writableURLs
                            + [stagedAttachments.directoryURL].compactMap { $0 },
                        target: target,
                        threadID: nil,
                        projectMemory: projectMemoryContext,
                        personalPreferences: personalPreferencesContext,
                        libraryContext: libraryContext,
                        contextHandoff: recoveryPlan.summary,
                        reasoningEffort: reasoningEffort
                    )
                    try await runProvider(retryRequest)
                }
                if !runCompletionRecorded {
                    await refreshRunChangeStats()
                    recordCompletion(usage: nil)
                }
                await finalizeActiveRun(status: .completed)
                isRunning = false
                statusText = "任务已完成"
                updateCurrentSession()
            } catch is CancellationError {
                await finalizeActiveRun(status: .cancelled)
                isRunning = false
                statusText = "任务已停止"
            } catch {
                await finalizeActiveRun(status: .failed, finalMessage: error.localizedDescription)
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
            markLatestHandoffDelivered()
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
        event: AgentContextHandoffEvent,
        sourceTargetID: String? = nil,
        destinationTarget: AgentProviderTarget? = nil
    ) {
        let now = Date.now
        contextSummary = plan.summary
        contextHandoffPending = true
        lastCompactedAt = now
        compactedEntryCount = plan.sourceEntryCount
        contextGeneration += 1
        lastInputTokens = nil
        threadID = nil
        handoffManifests.append(
            AgentHandoffManifest(
                generation: contextGeneration,
                kind: event.manifestKind,
                reason: plan.reason,
                sourceEntryCount: plan.sourceEntryCount,
                estimatedTokens: plan.estimatedTokens,
                sourceTargetID: sourceTargetID ?? activeTargetID,
                destinationTargetID: destinationTarget?.id ?? activeTargetID,
                destinationModelName: destinationTarget?.title,
                createdAt: now,
                content: plan.summary
            )
        )
        switch event {
        case .compaction:
            entries.append(.contextCompact(generation: contextGeneration, reason: plan.reason))
        case .modelSwitch(let modelName):
            entries.append(.modelSwitch(to: modelName, generation: contextGeneration))
        case .recovery:
            entries.append(.contextCompact(generation: contextGeneration, reason: plan.reason))
        }
        updateCurrentSession()
    }

    private func markLatestHandoffDelivered() {
        guard let index = handoffManifests.indices.last,
              handoffManifests[index].deliveredAt == nil else { return }
        handoffManifests[index].deliveredAt = .now
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

    private var currentArchive: AgentHistoryArchive {
        AgentHistoryArchive(
            selectedProjectID: selectedProjectID,
            selectedSessionID: selectedSessionID,
            projects: projects,
            inboxItems: inboxItems.isEmpty ? nil : inboxItems
        )
    }

    private var currentProject: AgentProjectRecord? {
        guard let projectID = selectedProjectID else { return nil }
        return projects.first(where: { $0.id == projectID })
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
        handoffManifests = session.handoffManifests
        referencedLibraryDocumentIDs = session.referencedLibraryDocumentIDs
        activeRunID = nil
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
        handoffManifests = []
        referencedLibraryDocumentIDs = []
        activeRunID = nil
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
        handoffManifests = []
        referencedLibraryDocumentIDs = []
        activeRunID = nil
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
        projects[projectIndex].sessions[sessionIndex].handoffs = handoffManifests.isEmpty
            ? nil
            : handoffManifests
        projects[projectIndex].sessions[sessionIndex].libraryDocumentIDs = referencedLibraryDocumentIDs.isEmpty
            ? nil
            : referencedLibraryDocumentIDs
        projects[projectIndex].sessions[sessionIndex].updatedAt = now
        projects[projectIndex].updatedAt = now
        persistHistory()
    }

    private func registerRun(_ record: AgentRunRecord) {
        guard let projectID = selectedProjectID, let sessionID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        if projects[projectIndex].sessions[sessionIndex].runs == nil {
            projects[projectIndex].sessions[sessionIndex].runs = []
        }
        projects[projectIndex].sessions[sessionIndex].runs?.append(record)
        activeRunID = record.id
        projects[projectIndex].sessions[sessionIndex].updatedAt = .now
        projects[projectIndex].updatedAt = .now
        persistHistory()
    }

    private func replaceRun(_ record: AgentRunRecord) {
        guard let projectID = selectedProjectID, let sessionID = selectedSessionID,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }),
              let runIndex = projects[projectIndex].sessions[sessionIndex].runs?.firstIndex(where: { $0.id == record.id }) else {
            return
        }
        projects[projectIndex].sessions[sessionIndex].runs?[runIndex] = record
        projects[projectIndex].sessions[sessionIndex].updatedAt = .now
        projects[projectIndex].updatedAt = .now
    }

    private func finalizeActiveRun(
        status: AgentRunStatus,
        finalMessage: String? = nil
    ) async {
        guard let runID = activeRunID,
              let workspaceURL,
              let run = currentSession?.runRecords.first(where: { $0.id == runID }) else {
            activeRunID = nil
            return
        }
        let checkpointStore = checkpointStore
        let finalizedRun = await Task.detached(priority: .utility) {
            checkpointStore.finishRun(
                run,
                workspaceURL: workspaceURL,
                status: status,
                finalMessage: finalMessage
            )
        }.value
        replaceRun(finalizedRun)
        activeRunID = nil
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
        do {
            try historyStore.save(currentArchive)
        } catch {
            statusText = "历史记录保存失败：\(error.localizedDescription)"
        }
    }

    private func libraryContext(matching prompt: String) -> String? {
        let documents = referencedLibraryDocuments
        guard !documents.isEmpty else { return nil }
        return documents.map { document in
            let excerpt = document.contextExcerpt(matching: prompt, maximumCharacters: 4_000)
            return """
            ## \(document.displayName)
            来源路径：\(document.path)
            类型：\(document.kindDisplayName)\(document.isDirectory ? "（已索引 \(document.indexedFileCount) 个文件）" : "")
            摘录：
            \(excerpt)
            """
        }.joined(separator: "\n\n")
    }

    func projectDisplayName(for projectID: UUID?) -> String? {
        guard let projectID else { return nil }
        return projects.first(where: { $0.id == projectID })?.displayName
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
