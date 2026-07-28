import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    @Query(sort: \AIModelConfiguration.sortOrder)
    private var modelConfigurations: [AIModelConfiguration]

    @Query(sort: \Skill.name)
    private var skills: [Skill]

    @Query(sort: \MediaRecord.createdAt, order: .reverse)
    private var mediaRecords: [MediaRecord]

    @State private var selectedSection: AppSection = .chat
    @State private var selectedConversationID: UUID?
    @State private var renameRequest: RenameRequest?
    @State private var destructiveRequest: DestructiveRequest?
    @State private var persistenceError: String?
    @State private var requestTasks: [UUID: Task<Void, Never>] = [:]
    @State private var requestIDs: [UUID: UUID] = [:]
    @State private var conversationStatus: [UUID: String] = [:]
    @StateObject private var videoGeneration = VideoGenerationCoordinator()
    @StateObject private var agentWorkspace = AgentWorkspaceViewModel()

    private let chatService = ChatService()

    private var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    private var enabledChatModels: [AIModelConfiguration] {
        modelConfigurations.filter {
            $0.isEnabled && $0.hasSupportedCategory && $0.category == .chat
        }
    }

    private var enabledAgentModels: [AIModelConfiguration] {
        modelConfigurations.filter {
            $0.isEnabled && $0.hasSupportedCategory && $0.category == .agent
        }
    }

    private var enabledSkills: [Skill] {
        skills.filter(\.isEnabled)
    }

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(
                conversations: conversations,
                agentViewModel: agentWorkspace,
                section: $selectedSection,
                selection: $selectedConversationID,
                onCreate: createConversation,
                onRename: requestRename,
                onClear: { requestDestructiveAction(.clear, for: $0) },
                onDelete: { requestDestructiveAction(.delete, for: $0) }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 280)
        } detail: {
            ZStack {
                AeroSceneBackground()

                switch selectedSection {
                case .chat:
                    if let conversation = selectedConversation {
                        ChatWorkspaceView(
                            conversation: conversation,
                            models: enabledChatModels,
                            skills: enabledSkills,
                            isGenerating: requestTasks[conversation.id] != nil,
                            statusText: conversationStatus[conversation.id],
                            onSelectModel: { updateSelectedModel($0, in: conversation) },
                            onSelectSkill: { updateSelectedSkill($0, in: conversation) },
                            onSend: { sendMessage($0, to: conversation) },
                            onCancel: { cancelRequest(for: conversation.id, showStatus: true) }
                        )
                        .id(conversation.id)
                    } else {
                        noConversationState
                    }

                case .agent:
                    AgentWorkspaceView(
                        models: enabledAgentModels,
                        viewModel: agentWorkspace
                    )

                case .media:
                    MediaWorkspaceView(videoGeneration: videoGeneration)

                case .models:
                    ModelSettingsView()

                case .skills:
                    SkillSettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .focusedSceneValue(\.newConversationAction, createConversation)
        .task {
            prepareApplicationData()
        }
        .onChange(of: conversations.map(\.id)) { _, conversationIDs in
            guard let selectedConversationID else {
                self.selectedConversationID = conversationIDs.first
                return
            }
            if !conversationIDs.contains(selectedConversationID) {
                self.selectedConversationID = conversationIDs.first
            }
        }
        .onChange(of: selectedConversationID) { oldValue, newValue in
            guard oldValue != newValue, let oldValue else { return }
            cancelRequest(for: oldValue, showStatus: true)
        }
        .onChange(of: selectedSection) { oldValue, newValue in
            guard oldValue == .chat, newValue != .chat,
                  let selectedConversationID else { return }
            cancelRequest(for: selectedConversationID, showStatus: true)
        }
        .onDisappear {
            cancelAllRequests()
            agentWorkspace.cancel()
        }
        .sheet(item: $renameRequest) { request in
            RenameConversationSheet(initialTitle: request.currentTitle) { title in
                renameConversation(id: request.conversationID, title: title)
            }
        }
        .alert(item: $destructiveRequest) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text(request.buttonTitle)) {
                    performDestructiveAction(request)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "无法保存更改",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(persistenceError ?? "未知错误")
        }
    }

    private var noConversationState: some View {
        VStack(spacing: 16) {
            Image("AppMark")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)

            Text("今天想聊点什么？")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(AeroTheme.text)

            Button(action: createConversation) {
                Label("新建聊天", systemImage: "plus")
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
    }

    private func prepareInitialConversation() {
        if conversations.isEmpty {
            createConversation()
        } else if selectedConversationID == nil {
            selectedConversationID = conversations.first?.id
        }
    }

    private func prepareApplicationData() {
        ModelConfigurationStore.migrateLegacyConfigurations(in: modelConfigurations)
        ModelConfigurationStore.normalizeDefaults(in: modelConfigurations)
        saveContext()

        try? ImageFileStore().reconcileStaging(
            liveRelativePaths: mediaRecords.filter(\.isImage).map(\.localRelativePath)
        )
        try? VideoFileStore().reconcileStaging(
            liveRelativePaths: mediaRecords.filter(\.isVideo).map(\.localRelativePath)
        )

        prepareInitialConversation()
    }

    private func createConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        selectedConversationID = conversation.id
        selectedSection = .chat
        saveContext()
    }

    private func requestRename(_ conversation: Conversation) {
        renameRequest = RenameRequest(conversationID: conversation.id, currentTitle: conversation.title)
    }

    private func renameConversation(id: UUID, title: String) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              let conversation = conversations.first(where: { $0.id == id }) else {
            return
        }

        conversation.title = normalizedTitle
        conversation.touch()
        saveContext()
    }

    private func requestDestructiveAction(_ kind: DestructiveRequest.Kind, for conversation: Conversation) {
        destructiveRequest = DestructiveRequest(conversationID: conversation.id, conversationTitle: conversation.title, kind: kind)
    }

    private func performDestructiveAction(_ request: DestructiveRequest) {
        guard let conversation = conversations.first(where: { $0.id == request.conversationID }) else {
            return
        }

        switch request.kind {
        case .clear:
            cancelRequest(for: conversation.id, showStatus: false)
            for message in Array(conversation.messages) {
                modelContext.delete(message)
            }
            conversation.touch()

        case .delete:
            cancelRequest(for: conversation.id, showStatus: false)
            let fallbackID = conversations.first(where: { $0.id != conversation.id })?.id
            modelContext.delete(conversation)
            if selectedConversationID == conversation.id {
                selectedConversationID = fallbackID
            }
        }

        saveContext()
    }

    private func updateSelectedModel(_ id: UUID?, in conversation: Conversation) {
        conversation.selectedModel = id.flatMap { selectedID in
            enabledChatModels.first { $0.id == selectedID }
        }
        conversation.touch()
        saveContext()
    }

    private func updateSelectedSkill(_ id: UUID?, in conversation: Conversation) {
        conversation.selectedSkill = id.flatMap { selectedID in
            enabledSkills.first { $0.id == selectedID }
        }
        conversation.touch()
        saveContext()
    }

    private func sendMessage(_ content: String, to conversation: Conversation) -> Bool {
        guard requestTasks[conversation.id] == nil else { return false }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return false }
        guard let model = ModelConfigurationStore.preferredChatModel(
            selected: conversation.selectedModel,
            from: modelConfigurations
        ) else {
            conversationStatus[conversation.id] = "请先在模型管理中启用一个聊天模型。"
            return false
        }

        let isFirstMessage = conversation.messages.isEmpty
        let nextSequence = (conversation.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            role: .user,
            content: normalizedContent,
            sequence: nextSequence,
            conversation: conversation
        )

        modelContext.insert(message)
        conversation.touch()

        if isFirstMessage && conversation.title == "新会话" {
            conversation.title = String(normalizedContent.prefix(24))
        }

        guard saveContext() else { return false }

        let target = makeTarget(from: model)
        let requestMessages = makeRequestMessages(for: conversation)
        let conversationID = conversation.id
        let requestID = UUID()
        let startedAt = Date()
        conversationStatus[conversationID] = nil
        requestIDs[conversationID] = requestID

        let task = Task {
            defer {
                finishRequest(for: conversationID, requestID: requestID)
            }

            do {
                let result = try await chatService.complete(
                    messages: requestMessages,
                    target: target
                )
                guard !Task.isCancelled, requestIDs[conversationID] == requestID,
                      let persistedConversation = conversations.first(where: { $0.id == conversationID }) else {
                    return
                }

                appendAssistantMessage(
                    content: result.content,
                    errorText: nil,
                    target: target,
                    startedAt: startedAt,
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    totalTokens: result.totalTokens,
                    to: persistedConversation
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestIDs[conversationID] == requestID,
                      let persistedConversation = conversations.first(where: { $0.id == conversationID }) else {
                    return
                }

                let errorText = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let readableError = errorText.isEmpty ? "模型请求失败。" : errorText
                appendAssistantMessage(
                    content: readableError,
                    errorText: readableError,
                    target: target,
                    startedAt: startedAt,
                    promptTokens: nil,
                    completionTokens: nil,
                    totalTokens: nil,
                    to: persistedConversation
                )
            }
        }
        requestTasks[conversationID] = task
        return true
    }

    private func makeRequestMessages(for conversation: Conversation) -> [ChatRequestMessage] {
        let history = conversation.orderedMessages.map {
            ChatContextMessageSnapshot(
                role: $0.role,
                content: $0.content,
                isFailed: $0.errorText != nil
            )
        }
        let skill = conversation.selectedSkill.flatMap { selectedSkill in
            selectedSkill.isEnabled
                ? ChatSkillPromptSnapshot(
                    name: selectedSkill.name,
                    systemPrompt: selectedSkill.systemPrompt
                )
                : nil
        }
        return ChatContextBuilder.makeMessages(history: history, skill: skill)
    }

    private func makeTarget(from model: AIModelConfiguration) -> ChatModelTarget {
        ChatModelTarget(
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            provider: model.provider,
            baseURLString: model.baseURLString,
            keychainAccount: model.keychainAccount
        )
    }

    private func appendAssistantMessage(
        content: String,
        errorText: String?,
        target: ChatModelTarget,
        startedAt: Date,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        to conversation: Conversation
    ) {
        let nextSequence = (conversation.messages.map(\.sequence).max() ?? -1) + 1
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let message = ChatMessage(
            role: .assistant,
            content: content,
            sequence: nextSequence,
            modelName: target.displayName,
            errorText: errorText,
            responseDurationMilliseconds: duration,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            conversation: conversation
        )

        modelContext.insert(message)
        conversation.touch()
        saveContext()
    }

    private func cancelRequest(for conversationID: UUID, showStatus: Bool) {
        guard requestTasks[conversationID] != nil else { return }
        requestTasks[conversationID]?.cancel()
        requestTasks[conversationID] = nil
        requestIDs[conversationID] = nil
        if showStatus {
            conversationStatus[conversationID] = "已停止生成。"
        }
    }

    private func finishRequest(for conversationID: UUID, requestID: UUID) {
        guard requestIDs[conversationID] == requestID else { return }
        requestTasks[conversationID] = nil
        requestIDs[conversationID] = nil
    }

    private func cancelAllRequests() {
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        requestIDs.removeAll()
    }

    @discardableResult
    private func saveContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            persistenceError = error.localizedDescription
            return false
        }
    }
}

private struct RenameRequest: Identifiable {
    let conversationID: UUID
    let currentTitle: String

    var id: UUID { conversationID }
}

private struct DestructiveRequest: Identifiable {
    enum Kind {
        case clear
        case delete
    }

    let conversationID: UUID
    let conversationTitle: String
    let kind: Kind

    var id: String { "\(conversationID.uuidString)-\(String(describing: kind))" }

    var title: String {
        switch kind {
        case .clear: "清空对话？"
        case .delete: "删除会话？"
        }
    }

    var message: String {
        switch kind {
        case .clear: "“\(conversationTitle)”中的消息将被永久删除。"
        case .delete: "“\(conversationTitle)”及其消息将被永久删除。"
        }
    }

    var buttonTitle: String {
        switch kind {
        case .clear: "清空"
        case .delete: "删除"
        }
    }
}

private struct RenameConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    let onSave: (String) -> Void

    init(initialTitle: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: initialTitle)
        self.onSave = onSave
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名会话")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AeroTheme.text)

            TextField("会话名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss()
                }
                Button("保存", action: save)
                    .buttonStyle(AeroPrimaryButtonStyle())
                    .disabled(normalizedTitle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(AeroTheme.mainBackground.opacity(0.88))
    }

    private func save() {
        guard !normalizedTitle.isEmpty else { return }
        onSave(normalizedTitle)
        dismiss()
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                Conversation.self,
                ChatMessage.self,
                AIModelConfiguration.self,
                Skill.self,
                MediaRecord.self,
            ],
            inMemory: true
        )
}
