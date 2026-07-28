import SwiftData
import SwiftUI

struct SkillSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.updatedAt, order: .reverse) private var skills: [Skill]

    @State private var editingSkillID: UUID?
    @State private var draft = SkillDraft.empty
    @State private var status: SkillSettingsStatus?
    @State private var deleteRequest: SkillDeleteRequest?

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
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text("删除 Skill？"),
                message: Text(request.message),
                primaryButton: .destructive(Text("删除")) {
                    deleteSkill(id: request.skillID)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        AeroWorkspaceHeader(
            eyebrow: "Skills",
            title: "Skills 管理",
            systemImage: "wand.and.stars"
        ) {
            Button(action: beginCreatingSkill) {
                Label("新增 Skill", systemImage: "plus")
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            HStack(spacing: 9) {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(status.message)
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
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 430)
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
                    Text(editingSkillID == nil ? "Create" : "Edit")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.deepLeaf)
                    Text(editingSkillID == nil ? "新增 Skill" : "编辑 Skill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                }

                Spacer()

                if editingSkillID != nil {
                    Button("取消", systemImage: "xmark", action: beginCreatingSkill)
                        .buttonStyle(.borderless)
                }
            }

            skillTextField("名称", placeholder: "输入 Skill 名称", text: $draft.name)

            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("简介")
                TextEditor(text: $draft.skillDescription)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 62)
                    .padding(8)
                    .skillInputSurface()
            }

            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("System Prompt")
                TextEditor(text: $draft.systemPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 190)
                    .padding(8)
                    .skillInputSurface()
            }

            Toggle("启用 Skill", isOn: $draft.isEnabled)
                .toggleStyle(.checkbox)

            Button(action: saveSkill) {
                Label(editingSkillID == nil ? "新增 Skill" : "保存更改", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AeroPrimaryButtonStyle())
        }
        .padding(24)
        .aeroGlass(cornerRadius: 24)
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Skills 列表")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AeroTheme.text)
                Spacer()
                Text("\(skills.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AeroTheme.sky.opacity(0.2))
                    .clipShape(Circle())
            }

            if skills.isEmpty {
                ContentUnavailableView("暂无 Skill", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(skills) { skill in
                        skillRow(skill)
                    }
                }
            }
        }
        .padding(22)
        .aeroGlass(cornerRadius: 24)
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(1)

                    if !skill.isEnabled {
                        Text("已停用")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AeroTheme.faintText)
                    }
                }

                if !skill.skillDescription.isEmpty {
                    Text(skill.skillDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.secondaryText)
                        .lineLimit(2)
                }

                if !skill.conversations.isEmpty {
                    Label("\(skill.conversations.count) 个会话", systemImage: "bubble.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.deepLeaf)
                }

                Text(skill.systemPrompt)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AeroTheme.faintText)
                    .lineLimit(3)
            }

            Spacer(minLength: 12)

            Button {
                beginEditing(skill)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑 Skill")

            Button(role: .destructive) {
                deleteRequest = SkillDeleteRequest(
                    skillID: skill.id,
                    skillName: skill.name,
                    conversationCount: skill.conversations.count
                )
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除 Skill")
        }
        .padding(14)
        .background(Color.white.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AeroTheme.deepSky.opacity(0.12), lineWidth: 1)
        }
    }

    private func skillTextField(
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
                .skillInputSurface()
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AeroTheme.secondaryText)
    }

    private func beginCreatingSkill() {
        editingSkillID = nil
        draft = .empty
        status = nil
    }

    private func beginEditing(_ skill: Skill) {
        editingSkillID = skill.id
        draft = SkillDraft(skill: skill)
        status = nil
    }

    private func saveSkill() {
        status = nil
        let content: NormalizedSkillContent
        do {
            content = try SkillConfigurationStore.normalizedContent(
                name: draft.name,
                skillDescription: draft.skillDescription,
                systemPrompt: draft.systemPrompt
            )
        } catch {
            status = .failure(error.localizedDescription)
            return
        }

        guard !SkillConfigurationStore.hasDuplicateName(
            content.name,
            editingID: editingSkillID,
            in: skills
        ) else {
            status = .failure("已存在同名 Skill。")
            return
        }

        let existingSkill = editingSkillID.flatMap { id in
            skills.first(where: { $0.id == id })
        }
        if editingSkillID != nil && existingSkill == nil {
            status = .failure("该 Skill 已不存在。")
            return
        }
        let skill = existingSkill ?? Skill(
            name: content.name,
            skillDescription: content.skillDescription,
            systemPrompt: content.systemPrompt,
            isEnabled: draft.isEnabled
        )

        skill.name = content.name
        skill.skillDescription = content.skillDescription
        skill.systemPrompt = content.systemPrompt
        skill.isEnabled = draft.isEnabled
        skill.updatedAt = .now

        if !draft.isEnabled {
            SkillConfigurationStore.clearConversationSelections(for: skill)
        }
        if existingSkill == nil {
            modelContext.insert(skill)
        }

        do {
            try modelContext.save()
            editingSkillID = skill.id
            draft = SkillDraft(skill: skill)
            status = .success(existingSkill == nil ? "Skill 已创建。" : "Skill 已更新。")
        } catch {
            modelContext.rollback()
            status = .failure(error.localizedDescription)
        }
    }

    private func deleteSkill(id: UUID) {
        guard let skill = skills.first(where: { $0.id == id }) else { return }

        SkillConfigurationStore.clearConversationSelections(for: skill)
        modelContext.delete(skill)

        do {
            try modelContext.save()
            if editingSkillID == id {
                beginCreatingSkill()
            }
            status = .success("Skill 已删除。")
        } catch {
            modelContext.rollback()
            status = .failure(error.localizedDescription)
        }
    }

}

private struct SkillDraft {
    var name: String
    var skillDescription: String
    var systemPrompt: String
    var isEnabled: Bool

    static let empty = SkillDraft(
        name: "",
        skillDescription: "",
        systemPrompt: "",
        isEnabled: true
    )

    init(skill: Skill) {
        self.init(
            name: skill.name,
            skillDescription: skill.skillDescription,
            systemPrompt: skill.systemPrompt,
            isEnabled: skill.isEnabled
        )
    }

    private init(
        name: String,
        skillDescription: String,
        systemPrompt: String,
        isEnabled: Bool
    ) {
        self.name = name
        self.skillDescription = skillDescription
        self.systemPrompt = systemPrompt
        self.isEnabled = isEnabled
    }
}

private struct SkillSettingsStatus {
    let message: String
    let isError: Bool

    static func success(_ message: String) -> SkillSettingsStatus {
        SkillSettingsStatus(message: message, isError: false)
    }

    static func failure(_ message: String) -> SkillSettingsStatus {
        SkillSettingsStatus(message: message, isError: true)
    }
}

private struct SkillDeleteRequest: Identifiable {
    let skillID: UUID
    let skillName: String
    let conversationCount: Int

    var id: UUID { skillID }

    var message: String {
        if conversationCount > 0 {
            return "“\(skillName)”正被 \(conversationCount) 个会话使用。删除后这些会话将不再使用 Skill。"
        }
        return "“\(skillName)”将被永久删除。"
    }
}

private struct SkillInputSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .aeroInputSurface(cornerRadius: 10)
    }
}

private extension View {
    func skillInputSurface() -> some View {
        modifier(SkillInputSurfaceModifier())
    }
}
