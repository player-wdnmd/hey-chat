import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 100)
                bubbleContent(label: "你")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AeroTheme.userBubbleGradient)
                    .clipShape(.rect(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 8, topTrailingRadius: 18))
                    .overlay {
                        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 8, topTrailingRadius: 18)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    }
                    .shadow(color: AeroTheme.deepSky.opacity(0.12), radius: 11, y: 5)
                    .frame(maxWidth: 640, alignment: .trailing)
            }

        case .assistant:
            HStack {
                bubbleContent(label: "Chat")
                    .frame(maxWidth: 840, alignment: .leading)
                Spacer(minLength: 40)
            }

        case .system:
            Text(message.content)
                .font(.system(size: 12))
                .foregroundStyle(AeroTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }

    private func bubbleContent(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.errorText == nil {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.faintText)
            } else {
                Label("请求失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.destructive)
            }

            Text(message.errorText ?? message.content)
                .font(.system(size: message.role == .assistant ? 14.5 : 14))
                .foregroundStyle(message.errorText == nil ? AeroTheme.text : AeroTheme.destructive)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                if let modelName = message.modelName, !modelName.isEmpty {
                    Text(modelName)
                }
                if let duration = message.responseDurationMilliseconds {
                    Text(formattedDuration(duration))
                }
                if let totalTokens = message.totalTokens {
                    Text("\(totalTokens) tokens")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AeroTheme.faintText)
        }
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
}
