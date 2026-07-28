import SwiftUI

struct MediaWorkspaceView: View {
    @ObservedObject var videoGeneration: VideoGenerationCoordinator
    @State private var mode: MediaWorkspaceMode = .image

    var body: some View {
        VStack(spacing: 0) {
            AeroMediaModeSwitcher(selection: $mode)
                .padding(.top, 18)
                .padding(.horizontal, 28)

            switch mode {
            case .image:
                ImageWorkspaceView()
            case .video:
                VideoWorkspaceView(generation: videoGeneration)
            }
        }
    }
}

private struct AeroMediaModeSwitcher: View {
    @Binding var selection: MediaWorkspaceMode
    @State private var hoveredMode: MediaWorkspaceMode?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MediaWorkspaceMode.allCases) { mode in
                modeButton(for: mode)
            }
        }
        .padding(4)
        .frame(width: 272, height: 46)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(AeroTheme.glassGradient.opacity(0.78))
                }
        }
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .overlay {
            Capsule()
                .inset(by: 1.5)
                .stroke(AeroTheme.deepSky.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: AeroTheme.deepSky.opacity(0.2), radius: 10, y: 5)
        .animation(.easeInOut(duration: 0.18), value: selection)
    }

    private func modeButton(for mode: MediaWorkspaceMode) -> some View {
        let isSelected = selection == mode
        let isHovered = hoveredMode == mode

        return Button {
            selection = mode
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : AeroTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(Color.white.opacity(isHovered && !isSelected ? 0.46 : 0.2))

            Capsule()
                .fill(AeroTheme.primaryButtonGradient)
                .opacity(isSelected ? 1 : 0)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .padding(1)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay {
            Capsule()
                .stroke(
                    isSelected ? Color.white.opacity(0.78) : AeroTheme.deepSky.opacity(0.1),
                    lineWidth: 1
                )
        }
        .shadow(
            color: isSelected ? AeroTheme.deepLeaf.opacity(0.28) : .clear,
            radius: 5,
            y: 2
        )
        .onHover { isHovering in
            if isHovering {
                hoveredMode = mode
            } else if hoveredMode == mode {
                hoveredMode = nil
            }
        }
        .help(mode.helpText)
        .accessibilityLabel(mode.title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum MediaWorkspaceMode: CaseIterable, Hashable, Identifiable {
    case image
    case video

    var id: Self { self }

    var title: String {
        switch self {
        case .image:
            "图片"
        case .video:
            "视频"
        }
    }

    var systemImage: String {
        switch self {
        case .image:
            "photo"
        case .video:
            "play.rectangle"
        }
    }

    var helpText: String {
        switch self {
        case .image:
            "切换到图片工具"
        case .video:
            "切换到视频工具"
        }
    }
}
