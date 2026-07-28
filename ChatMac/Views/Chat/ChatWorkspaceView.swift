import SwiftUI

struct ChatWorkspaceView: View {
    let conversation: Conversation
    let models: [AIModelConfiguration]
    let skills: [Skill]
    let isGenerating: Bool
    let statusText: String?
    let onSelectModel: (UUID?) -> Void
    let onSelectSkill: (UUID?) -> Void
    let onSend: (String) -> Bool
    let onCancel: () -> Void

    @State private var draft = ""

    private var messages: [ChatMessage] {
        conversation.orderedMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if messages.isEmpty {
                        emptyState
                            .containerRelativeFrame(.vertical)
                    } else {
                        LazyVStack(spacing: 22) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            if isGenerating {
                                generatingIndicator
                                    .id("assistant-generating")
                            }
                        }
                        .frame(maxWidth: 880)
                        .padding(.vertical, 18)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: messages.last?.id) { _, messageID in
                    guard let messageID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(messageID, anchor: .bottom)
                    }
                }
                .onChange(of: isGenerating) { _, isGenerating in
                    guard isGenerating else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("assistant-generating", anchor: .bottom)
                    }
                }
            }

            ComposerView(
                draft: $draft,
                selectedModelID: conversation.selectedModel?.id,
                selectedSkillID: conversation.selectedSkill?.id,
                models: models,
                skills: skills,
                messageCount: messages.count,
                isGenerating: isGenerating,
                statusText: statusText,
                onSelectModel: onSelectModel,
                onSelectSkill: onSelectSkill,
                onSend: sendDraft,
                onCancel: onCancel
            )
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 20)
            .background {
                LinearGradient(
                    colors: [Color.white.opacity(0), Color(red: 244 / 255, green: 251 / 255, blue: 247 / 255).opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private var generatingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在生成回复…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: 840)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Chat")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color(red: 15 / 255, green: 118 / 255, blue: 110 / 255))

            Text("今天想聊点什么？")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Color(red: 15 / 255, green: 61 / 255, blue: 92 / 255))
                .shadow(color: AeroTheme.deepSky.opacity(0.14), radius: 12, y: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }

    private func sendDraft() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isGenerating else { return }
        if onSend(content) {
            draft = ""
        }
    }
}
