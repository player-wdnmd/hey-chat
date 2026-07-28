import AppKit
import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let selectedModelID: UUID?
    let selectedSkillID: UUID?
    let models: [AIModelConfiguration]
    let skills: [Skill]
    let messageCount: Int
    let isGenerating: Bool
    let statusText: String?
    let onSelectModel: (UUID?) -> Void
    let onSelectSkill: (UUID?) -> Void
    let onSend: () -> Void
    let onCancel: () -> Void

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldDeferReturnToTextInput: Bool {
        guard let textInputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient else {
            return true
        }
        return textInputClient.hasMarkedText()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(composerStatus)
                Spacer()
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(messageCount == 0 ? "尚未发送消息" : "\(messageCount) 条消息")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AeroTheme.faintText)

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Text("Skills / 模型")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AeroTheme.faintText)

                    Spacer()

                    skillMenu
                    modelMenu
                }

                TextEditor(text: $draft)
                    .font(.system(size: 14.5))
                    .foregroundStyle(AeroTheme.text)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .onKeyPress(keys: [.return], phases: [.down]) { keyPress in
                        if keyPress.modifiers.contains(.shift) || shouldDeferReturnToTextInput {
                            return .ignored
                        }
                        guard !trimmedDraft.isEmpty, !isGenerating else {
                            return .handled
                        }
                        onSend()
                        return .handled
                    }

                HStack {
                    Spacer()

                    if isGenerating {
                        Button(action: onCancel) {
                            Label("停止", systemImage: "stop.fill")
                                .frame(minWidth: 58)
                        }
                        .buttonStyle(AeroPrimaryButtonStyle())
                        .help("停止生成")
                    } else {
                        Button(action: onSend) {
                            Label("发送", systemImage: "arrow.up")
                                .frame(minWidth: 58)
                        }
                        .buttonStyle(AeroPrimaryButtonStyle())
                        .disabled(trimmedDraft.isEmpty)
                        .help("发送消息")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .aeroGlass(cornerRadius: 22)
        }
        .frame(maxWidth: 880)
    }

    private var composerStatus: String {
        if isGenerating {
            return "正在连接模型"
        }
        if let statusText, !statusText.isEmpty {
            return statusText
        }
        return messageCount == 0 ? "Ready" : "已保存到本地"
    }

    private var skillMenu: some View {
        Menu {
            Button {
                onSelectSkill(nil)
            } label: {
                optionLabel("无 Skill", selected: selectedSkillID == nil)
            }

            if !skills.isEmpty {
                Divider()
            }

            ForEach(skills) { skill in
                Button {
                    onSelectSkill(skill.id)
                } label: {
                    optionLabel(skill.name, selected: selectedSkillID == skill.id)
                }
            }
        } label: {
            selectorLabel(selectedSkillName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isGenerating)
    }

    private var modelMenu: some View {
        Menu {
            Button {
                onSelectModel(nil)
            } label: {
                optionLabel("默认模型", selected: selectedModelID == nil)
            }

            if !models.isEmpty {
                Divider()
            }

            ForEach(models) { model in
                Button {
                    onSelectModel(model.id)
                } label: {
                    optionLabel(model.displayName, selected: selectedModelID == model.id)
                }
            }
        } label: {
            selectorLabel(selectedModelName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isGenerating)
    }

    private var selectedSkillName: String {
        skills.first(where: { $0.id == selectedSkillID })?.name ?? "无 Skill"
    }

    private var selectedModelName: String {
        models.first(where: { $0.id == selectedModelID })?.displayName ?? "默认模型"
    }

    private func selectorLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AeroTheme.text)
        .padding(.horizontal, 12)
        .frame(minWidth: 150, minHeight: 32)
        .background(Color.white.opacity(0.72))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AeroTheme.deepSky.opacity(0.2), lineWidth: 1))
    }

    private func optionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }
}
