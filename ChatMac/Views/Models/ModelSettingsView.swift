import SwiftData
import SwiftUI

struct ModelSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var models: [AIModelConfiguration]

    @State private var editingModelID: UUID?
    @State private var draft = ModelDraft.empty
    @State private var apiKey = ""
    @State private var hasStoredAPIKey = false
    @State private var status: ModelSettingsStatus?
    @State private var deleteRequest: ModelDeleteRequest?
    @State private var isRemovingKey = false
    @State private var testingModelID: UUID?
    @State private var connectionRequestID: UUID?
    @State private var connectionTask: Task<Void, Never>?

    private let keychain = KeychainService()
    private let chatService = ChatService()

    private let visibleCategories: [AIModelCategory] = [.chat, .agent, .image, .video]

    private var sortedModels: [AIModelConfiguration] {
        ModelConfigurationStore.sorted(
            models.filter { visibleCategories.contains($0.category) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                statusView
                responsivePanels
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .onDisappear {
            cancelConnectionTest()
        }
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text("删除模型？"),
                message: Text(request.message),
                primaryButton: .destructive(Text("删除")) {
                    deleteModel(id: request.modelID)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("移除 API Key？", isPresented: $isRemovingKey) {
            Button("移除", role: .destructive, action: removeStoredKey)
            Button("取消", role: .cancel) {}
        } message: {
            Text("Keychain 中保存的密钥将被永久移除。")
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Models")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.82))

                Text("模型管理")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(.white)
            }

            Spacer()

            Button(action: beginCreatingModel) {
                Label("新增模型", systemImage: "plus")
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background {
            LinearGradient(
                colors: [AeroTheme.sky, AeroTheme.deepSky, AeroTheme.leaf],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 1)
        }
        .shadow(color: AeroTheme.deepSky.opacity(0.18), radius: 16, y: 8)
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            HStack(spacing: 9) {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(status.message)
                    .textSelection(.enabled)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.isError ? AeroTheme.destructive : AeroTheme.deepLeaf)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Color.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var responsivePanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                editorPanel
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 410)
                libraryPanel
                    .frame(minWidth: 380, maxWidth: .infinity)
            }

            VStack(spacing: 24) {
                editorPanel
                libraryPanel
            }
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingModelID == nil ? "Create" : "Edit")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.deepLeaf)
                    Text(editingModelID == nil ? "新增模型" : "编辑模型")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                }

                Spacer()

                if editingModelID != nil {
                    Button("取消", systemImage: "xmark", action: beginCreatingModel)
                        .buttonStyle(.borderless)
                }
            }

            modelTextField("模型标识", placeholder: "输入服务端模型标识", text: $draft.modelIdentifier)
            modelTextField("显示名称", placeholder: "输入本机显示名称", text: $draft.displayName)

            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("模型说明")
                TextEditor(text: $draft.modelDescription)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 62)
                    .padding(8)
                    .modelInputSurface()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("模型分类")
                    Picker("模型分类", selection: $draft.category) {
                        ForEach(visibleCategories, id: \.self) { category in
                            Label(category.displayName, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onChange(of: draft.category) { _, category in
                        let supportedKinds = MediaAPIKind.supportedCases(for: category)
                        if !supportedKinds.contains(draft.mediaAPIKind) {
                            draft.mediaAPIKind = MediaAPIKind.defaultValue(for: category)
                        }
                        if category == .agent {
                            if !AgentEngineKind.configurationChannels.contains(draft.agentEngine) {
                                applyAgentChannel(.codexCLI)
                            } else {
                                applyAgentChannel(draft.agentEngine)
                            }
                        } else {
                            draft.agentEngine = .disabled
                            draft.agentReasoningEffort = .automatic
                        }
                        if category == .image || category == .video {
                            draft.provider = .openAICompatible
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel(draft.category == .agent ? "Agent 渠道" : "兼容协议")
                    Group {
                        if draft.category == .agent {
                            Picker("Agent 渠道", selection: $draft.agentEngine) {
                                ForEach(AgentEngineKind.configurationChannels, id: \.self) { engine in
                                    Label(engine.channelDisplayName, systemImage: engine.systemImage)
                                        .tag(engine)
                                }
                            }
                            .onChange(of: draft.agentEngine) { _, engine in
                                applyAgentChannel(engine)
                            }
                        } else {
                            Picker("兼容协议", selection: $draft.provider) {
                                ForEach(supportedProviders, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if draft.category != .agent {
                modelTextField(
                    "渠道名称",
                    placeholder: "例如 OpenAI、OpenRouter 或自定义中转站",
                    text: $draft.channelName
                )
            }

            if draft.category == .image || draft.category == .video {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("媒体接口")
                    Picker("媒体接口", selection: $draft.mediaAPIKind) {
                        ForEach(MediaAPIKind.supportedCases(for: draft.category), id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            modelTextField("Base URL", placeholder: "输入 API Base URL", text: $draft.baseURLString)

            if draft.category == .agent {
                agentConfigurationPanel
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    fieldLabel("API Key")
                    Spacer()
                    if hasStoredAPIKey {
                        Label("已保存在 Keychain", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AeroTheme.deepLeaf)
                    }
                }

                SecureField(hasStoredAPIKey ? "留空则继续使用已保存密钥" : "输入 API Key", text: $apiKey)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .modelInputSurface()

                if hasStoredAPIKey {
                    Button("移除已保存密钥", systemImage: "key.slash") {
                        isRemovingKey = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AeroTheme.destructive)
                }
            }

            HStack(spacing: 18) {
                Toggle("启用模型", isOn: $draft.isEnabled)
                Toggle("设为默认", isOn: $draft.isDefault)
            }
            .toggleStyle(.checkbox)

            HStack {
                fieldLabel("排序值")
                TextField("排序值", value: $draft.sortOrder, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                Spacer()
            }

            Button(action: saveModel) {
                Label(editingModelID == nil ? "新增模型" : "保存更改", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
        .padding(24)
        .aeroGlass(cornerRadius: 24)
    }

    private var agentConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .opacity(0.45)

            Label("Agent 运行配置", systemImage: "terminal.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AeroTheme.deepLeaf)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Agent 协议")
                    Picker("Agent 协议", selection: $draft.agentAPIKind) {
                        ForEach(draft.agentEngine.supportedAPIs, id: \.self) { api in
                            Text(api.displayName).tag(api)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("默认推理强度")
                    Picker("默认推理强度", selection: $draft.agentReasoningEffort) {
                        ForEach(draft.agentEngine.supportedReasoningEfforts, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Text(agentConfigurationHint)
                .font(.system(size: 10.5))
                .foregroundStyle(AeroTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var agentConfigurationHint: String {
        switch draft.agentEngine {
        case .disabled:
            return ""
        case .codexCLI:
            return "当前 Codex CLI 仅支持 Responses API。使用当前渠道的 Base URL 与 API Key，不读取 Codex 账号。"
        case .claudeCodeCLI:
            return "Claude Code 使用当前渠道的 Anthropic Messages 端点与 API Key，不读取 Claude 账号；Base URL 末尾的 /v1 会自动处理。"
        case .grokBuildCLI:
            return "Grok Build 支持 Responses 和 Chat Completions。Base URL 与 API Key 来自当前渠道，不使用 Grok 账号。"
        }
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("模型列表")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AeroTheme.text)
                Spacer()
                Text("\(sortedModels.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AeroTheme.sky.opacity(0.2))
                    .clipShape(Circle())
            }

            if sortedModels.isEmpty {
                ContentUnavailableView("暂无模型", systemImage: "cpu")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(visibleCategories, id: \.self) { category in
                        let categoryModels = sortedModels.filter { $0.category == category }
                        if !categoryModels.isEmpty {
                            modelCategorySection(category, models: categoryModels)
                        }
                    }
                }
            }
        }
        .padding(22)
        .aeroGlass(cornerRadius: 24)
    }

    private func modelCategorySection(
        _ category: AIModelCategory,
        models: [AIModelConfiguration]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                categorySectionTitle(category),
                systemImage: category.systemImage
            )
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AeroTheme.secondaryText)

            if category == .agent {
                ForEach(AgentEngineKind.configurationChannels, id: \.self) { engine in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: engine.systemImage)
                            Text(engine.channelDisplayName)
                            Spacer()
                            Text("\(models.filter { $0.agentEngine == engine }.count)")
                                .foregroundStyle(AeroTheme.faintText)
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AeroTheme.deepSky)

                        let channelModels = models.filter { $0.agentEngine == engine }
                        if channelModels.isEmpty {
                            Text("尚未配置 \(engine.channelDisplayName) 渠道模型")
                                .font(.system(size: 10.5))
                                .foregroundStyle(AeroTheme.faintText)
                                .padding(.vertical, 5)
                        } else {
                            ForEach(channelModels) { model in
                                modelRow(model)
                            }
                        }
                    }
                    .padding(.vertical, 6)

                    if engine != AgentEngineKind.configurationChannels.last {
                        Divider().opacity(0.35)
                    }
                }
            } else {
                ForEach(models) { model in
                    modelRow(model)
                }
            }
        }
    }

    private func modelRow(_ model: AIModelConfiguration) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(1)
                    if model.isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.92, green: 0.62, blue: 0.12))
                    }
                    if !model.isEnabled {
                        Text("已停用")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AeroTheme.faintText)
                    }
                }

                Text(model.modelIdentifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .lineLimit(1)

                Text(modelSummary(model))
                    .font(.system(size: 10))
                    .foregroundStyle(AeroTheme.faintText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if model.category == .chat {
                Button {
                    testConnection(model)
                } label: {
                    if testingModelID == model.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(testingModelID != nil || !model.isEnabled)
                .help("测试连接")
            }

            Button {
                beginEditing(model)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑模型")

            Button(role: .destructive) {
                deleteRequest = ModelDeleteRequest(
                    modelID: model.id,
                    modelName: model.displayName,
                    conversationCount: model.conversations.count
                )
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除模型")
        }
        .padding(14)
        .background(Color.white.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AeroTheme.deepSky.opacity(0.12), lineWidth: 1)
        }
    }

    private func modelTextField(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .modelInputSurface()
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AeroTheme.secondaryText)
    }

    private func beginCreatingModel() {
        cancelConnectionTest()
        editingModelID = nil
        draft = .empty
        apiKey = ""
        hasStoredAPIKey = false
        status = nil
    }

    private func beginEditing(_ model: AIModelConfiguration) {
        cancelConnectionTest()
        editingModelID = model.id
        draft = ModelDraft(model: model)
        apiKey = ""
        do {
            hasStoredAPIKey = try keychain.containsValue(account: model.keychainAccount)
            status = nil
        } catch {
            hasStoredAPIKey = false
            status = .failure(error.localizedDescription)
        }
    }

    private func saveModel() {
        status = nil
        let normalizedIdentifier = draft.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelName = draft.channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = draft.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedIdentifier.isEmpty else {
            status = .failure("模型标识不能为空。")
            return
        }
        guard !normalizedName.isEmpty else {
            status = .failure("显示名称不能为空。")
            return
        }
        guard isValidBaseURL(normalizedBaseURL) else {
            status = .failure("Base URL 必须是有效的 HTTP 或 HTTPS 地址。")
            return
        }
        if draft.category == .agent {
            guard AgentEngineKind.configurationChannels.contains(draft.agentEngine) else {
                status = .failure("请选择 Codex 或 Claude Agent 渠道。")
                return
            }
            guard draft.agentEngine.supportedAPIs.contains(draft.agentAPIKind) else {
                status = .failure("当前 Agent 引擎不支持所选接口协议。")
                return
            }
            let agentBaseURL = draft.agentBaseURLString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard agentBaseURL.isEmpty || isValidBaseURL(agentBaseURL) else {
                status = .failure("Agent Base URL 必须是有效的 HTTP 或 HTTPS 地址。")
                return
            }
        }
        if (draft.category == .image || draft.category == .video)
            && draft.provider != .openAICompatible {
            status = .failure("图片和视频接口仅支持 OpenAI 兼容协议。")
            return
        }
        if (draft.category == .image || draft.category == .video),
           !MediaAPIKind.supportedCases(for: draft.category).contains(draft.mediaAPIKind) {
            status = .failure("当前模型分类不支持所选媒体接口。")
            return
        }
        guard !models.contains(where: {
            $0.id != editingModelID
                && $0.category == draft.category
                && $0.provider == draft.provider
                && $0.baseURLString.caseInsensitiveCompare(normalizedBaseURL) == .orderedSame
                && $0.modelIdentifier.caseInsensitiveCompare(normalizedIdentifier) == .orderedSame
        }) else {
            if draft.category == .agent {
                status = .failure(
                    "\(draft.agentEngine.channelDisplayName) Agent 渠道中已存在该模型，请编辑右侧已有配置。"
                )
            } else {
                status = .failure("同一渠道地址和协议下已存在该模型标识。")
            }
            return
        }
        let existingModel = editingModelID.flatMap { id in models.first(where: { $0.id == id }) }
        let model = existingModel ?? AIModelConfiguration(
            modelIdentifier: normalizedIdentifier,
            displayName: normalizedName,
            category: draft.category,
            provider: draft.provider,
            mediaAPIKind: isMediaCategory(draft.category) ? draft.mediaAPIKind : nil,
            channelName: normalizedChannelName.isEmpty ? nil : normalizedChannelName,
            baseURLString: normalizedBaseURL
        )
        let previousKey: String?
        do {
            previousKey = try keychain.read(account: model.keychainAccount)
        } catch {
            status = .failure(error.localizedDescription)
            return
        }
        var didWriteKey = false
        let shouldReassignConversations = existingModel?.category == .chat
            && (draft.category != .chat || !draft.isEnabled)
        let replacementChatModel = shouldReassignConversations
            ? ModelConfigurationStore.preferredChatModel(
                selected: nil,
                from: models.filter { $0.id != model.id }
            )
            : nil

        do {
            if !normalizedKey.isEmpty {
                try keychain.save(normalizedKey, account: model.keychainAccount)
                didWriteKey = true
            }

            model.modelIdentifier = normalizedIdentifier
            model.displayName = normalizedName
            model.modelDescription = draft.modelDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            model.category = draft.category
            model.provider = draft.provider
            model.mediaAPIKindRawValue = isMediaCategory(draft.category)
                ? draft.mediaAPIKind.rawValue
                : nil
            model.channelName = draft.category == .agent
                ? draft.agentEngine.channelDisplayName
                : (normalizedChannelName.isEmpty ? nil : normalizedChannelName)
            model.baseURLString = normalizedBaseURL
            model.agentEngine = draft.category == .agent ? draft.agentEngine : .disabled
            model.agentAPIKindRawValue = draft.category == .agent
                ? draft.agentAPIKind.rawValue
                : nil
            model.agentCredentialRawValue = draft.category == .agent
                ? "apiKey"
                : nil
            model.agentModelIdentifier = nil
            model.agentBaseURLString = nil
            model.agentReasoningEffort = draft.category == .agent
                ? draft.agentReasoningEffort
                : .automatic
            model.sortOrder = draft.sortOrder
            model.isEnabled = draft.isEnabled
            model.isDefault = draft.isDefault
            model.updatedAt = .now

            if shouldReassignConversations {
                for conversation in Array(model.conversations) {
                    conversation.selectedModel = replacementChatModel
                    conversation.touch()
                }
            }

            if existingModel == nil {
                modelContext.insert(model)
            }
            ModelConfigurationStore.normalizeDefaults(
                in: existingModel == nil ? models + [model] : models,
                preferredID: draft.isDefault && draft.isEnabled ? model.id : nil
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if didWriteKey {
                do {
                    try restoreKey(previousKey, account: model.keychainAccount)
                } catch let restoreError {
                    status = .failure(
                        "保存失败：\(error.localizedDescription) Keychain 恢复也失败：\(restoreError.localizedDescription)"
                    )
                    return
                }
            }
            status = .failure(error.localizedDescription)
            return
        }

        editingModelID = model.id
        draft = ModelDraft(model: model)
        apiKey = ""
        hasStoredAPIKey = !normalizedKey.isEmpty || previousKey != nil
        status = .success(existingModel == nil ? "模型已创建。" : "模型已更新。")
    }

    private func deleteModel(id: UUID) {
        guard let model = models.first(where: { $0.id == id }) else { return }
        if testingModelID == id {
            cancelConnectionTest()
        }

        let oldKey: String?
        do {
            oldKey = try keychain.read(account: model.keychainAccount)
        } catch {
            status = .failure(error.localizedDescription)
            return
        }

        do {
            try keychain.delete(account: model.keychainAccount)

            let remainingModels = models.filter { $0.id != model.id }
            ModelConfigurationStore.normalizeDefaults(in: remainingModels)
            let replacement = ModelConfigurationStore.preferredChatModel(selected: nil, from: remainingModels)
            for conversation in Array(model.conversations) {
                conversation.selectedModel = model.category == .chat ? replacement : nil
                conversation.touch()
            }

            modelContext.delete(model)
            try modelContext.save()

            if editingModelID == id {
                beginCreatingModel()
            }
            status = .success("模型已删除。")
        } catch {
            modelContext.rollback()
            do {
                try restoreKey(oldKey, account: model.keychainAccount)
                status = .failure(error.localizedDescription)
            } catch let restoreError {
                status = .failure(
                    "删除失败：\(error.localizedDescription) Keychain 恢复也失败：\(restoreError.localizedDescription)"
                )
            }
        }
    }

    private func removeStoredKey() {
        guard let modelID = editingModelID,
              let model = models.first(where: { $0.id == modelID }) else {
            return
        }

        do {
            try keychain.delete(account: model.keychainAccount)
            apiKey = ""
            hasStoredAPIKey = false
            status = .success("API Key 已从 Keychain 移除。")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func testConnection(_ model: AIModelConfiguration) {
        cancelConnectionTest()
        let requestID = UUID()
        connectionRequestID = requestID
        testingModelID = model.id
        status = nil
        let target = makeTarget(model)

        connectionTask = Task {
            defer {
                if connectionRequestID == requestID {
                    testingModelID = nil
                    connectionRequestID = nil
                    connectionTask = nil
                }
            }

            do {
                let result = try await chatService.complete(
                    messages: [ChatRequestMessage(role: .user, content: "请只回复 OK")],
                    target: target,
                    maxTokens: 8
                )
                guard !Task.isCancelled, connectionRequestID == requestID else { return }
                status = .success("连接成功：\(String(result.content.prefix(80)))")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, connectionRequestID == requestID else { return }
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func cancelConnectionTest() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionRequestID = nil
        testingModelID = nil
    }

    private func makeTarget(_ model: AIModelConfiguration) -> ChatModelTarget {
        ChatModelTarget(
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            provider: model.provider,
            baseURLString: model.baseURLString,
            keychainAccount: model.keychainAccount
        )
    }

    private func restoreKey(_ value: String?, account: String) throws {
        if let value {
            try keychain.save(value, account: account)
        } else {
            try keychain.delete(account: account)
        }
    }

    private func isValidBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }
        return url.host != nil
    }

    private var supportedProviders: [AIProviderKind] {
        draft.category == .chat ? AIProviderKind.allCases : [.openAICompatible]
    }

    private func isMediaCategory(_ category: AIModelCategory) -> Bool {
        category == .image || category == .video
    }

    private func applyAgentChannel(_ engine: AgentEngineKind) {
        guard AgentEngineKind.configurationChannels.contains(engine) else { return }
        draft.agentEngine = engine
        draft.provider = engine.defaultProvider
        draft.channelName = engine.channelDisplayName
        if !engine.supportedAPIs.contains(draft.agentAPIKind),
           let defaultAPI = engine.supportedAPIs.first {
            draft.agentAPIKind = defaultAPI
        }
        if !engine.supportedReasoningEfforts.contains(draft.agentReasoningEffort) {
            draft.agentReasoningEffort = .automatic
        }
        draft.agentModelIdentifier = ""
        draft.agentBaseURLString = ""
    }

    private func modelSummary(_ model: AIModelConfiguration) -> String {
        if model.category == .agent {
            return "\(model.agentEngine.channelDisplayName) · \(model.agentAPIKind.displayName) · 推理 \(model.agentReasoningEffort.displayName)"
        }
        if isMediaCategory(model.category) {
            return "\(model.resolvedChannelName) · \(model.mediaAPIKind.displayName) · \(model.baseURLString)"
        }
        return "\(model.resolvedChannelName) · \(model.provider.displayName) · \(model.baseURLString)"
    }

    private func categorySectionTitle(_ category: AIModelCategory) -> String {
        switch category {
        case .chat: "对话模型"
        case .agent: "Agent 模型"
        case .image: "图片模型"
        case .video: "视频模型"
        }
    }
}

private struct ModelDraft {
    var modelIdentifier: String
    var displayName: String
    var channelName: String
    var modelDescription: String
    var category: AIModelCategory
    var provider: AIProviderKind
    var mediaAPIKind: MediaAPIKind
    var baseURLString: String
    var agentEngine: AgentEngineKind
    var agentAPIKind: AgentAPIKind
    var agentModelIdentifier: String
    var agentBaseURLString: String
    var agentReasoningEffort: AgentReasoningEffort
    var sortOrder: Int
    var isEnabled: Bool
    var isDefault: Bool

    static let empty = ModelDraft(
        modelIdentifier: "",
        displayName: "",
        channelName: "",
        modelDescription: "",
        category: .chat,
        provider: .openAICompatible,
        mediaAPIKind: .imageGenerations,
        baseURLString: "",
        agentEngine: .codexCLI,
        agentAPIKind: .responses,
        agentModelIdentifier: "",
        agentBaseURLString: "",
        agentReasoningEffort: .automatic,
        sortOrder: 0,
        isEnabled: true,
        isDefault: false
    )

    init(model: AIModelConfiguration) {
        self.init(
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            channelName: model.category == .agent
                ? model.agentEngine.channelDisplayName
                : (model.channelName ?? ""),
            modelDescription: model.modelDescription,
            category: model.category,
            provider: model.provider,
            mediaAPIKind: model.mediaAPIKind,
            baseURLString: model.baseURLString,
            agentEngine: model.category == .agent && model.agentEngine == .disabled
                ? (model.provider == .anthropicCompatible ? .claudeCodeCLI : .codexCLI)
                : model.agentEngine,
            agentAPIKind: model.agentAPIKind,
            agentModelIdentifier: model.agentModelIdentifier ?? "",
            agentBaseURLString: model.agentBaseURLString ?? "",
            agentReasoningEffort: model.agentReasoningEffort,
            sortOrder: model.sortOrder,
            isEnabled: model.isEnabled,
            isDefault: model.isDefault
        )
    }

    private init(
        modelIdentifier: String,
        displayName: String,
        channelName: String,
        modelDescription: String,
        category: AIModelCategory,
        provider: AIProviderKind,
        mediaAPIKind: MediaAPIKind,
        baseURLString: String,
        agentEngine: AgentEngineKind,
        agentAPIKind: AgentAPIKind,
        agentModelIdentifier: String,
        agentBaseURLString: String,
        agentReasoningEffort: AgentReasoningEffort,
        sortOrder: Int,
        isEnabled: Bool,
        isDefault: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName
        self.channelName = channelName
        self.modelDescription = modelDescription
        self.category = category
        self.provider = provider
        self.mediaAPIKind = mediaAPIKind
        self.baseURLString = baseURLString
        self.agentEngine = agentEngine
        self.agentAPIKind = agentAPIKind
        self.agentModelIdentifier = agentModelIdentifier
        self.agentBaseURLString = agentBaseURLString
        self.agentReasoningEffort = agentReasoningEffort
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }
}

private struct ModelSettingsStatus {
    let message: String
    let isError: Bool

    static func success(_ message: String) -> ModelSettingsStatus {
        ModelSettingsStatus(message: message, isError: false)
    }

    static func failure(_ message: String) -> ModelSettingsStatus {
        ModelSettingsStatus(message: message, isError: true)
    }
}

private struct ModelDeleteRequest: Identifiable {
    let modelID: UUID
    let modelName: String
    let conversationCount: Int

    var id: UUID { modelID }

    var message: String {
        if conversationCount > 0 {
            return "“\(modelName)”正被 \(conversationCount) 个会话使用。删除后这些会话将切换到默认模型。"
        }
        return "“\(modelName)”及其 Keychain 密钥将被永久删除。"
    }
}

private struct ModelInputSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AeroTheme.deepSky.opacity(0.2), lineWidth: 1)
            }
    }
}

private extension View {
    func modelInputSurface() -> some View {
        modifier(ModelInputSurfaceModifier())
    }
}
