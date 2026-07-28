import AppKit
import SwiftUI

struct ConversationSidebar: View {
    let conversations: [Conversation]
    @ObservedObject var agentViewModel: AgentWorkspaceViewModel
    @Binding var section: AppSection
    @Binding var selection: UUID?
    let onCreate: () -> Void
    let onRename: (Conversation) -> Void
    let onClear: (Conversation) -> Void
    let onDelete: (Conversation) -> Void
    @State private var agentDeleteRequest: AgentHistoryDeleteRequest?

    var body: some View {
        VStack(spacing: 16) {
            brand
            sectionPicker

            switch section {
            case .chat:
                createButton
                historyHeader
                conversationList

            case .agent:
                agentActions
                agentHistoryHeader
                agentProjectList

            case .media:
                settingsItem(
                    title: "媒体工具",
                    subtitle: "图片与视频",
                    systemImage: "photo.stack"
                )
                Spacer(minLength: 0)

            case .skills:
                settingsItem(
                    title: "Skills 管理",
                    subtitle: "本机提示词",
                    systemImage: "wand.and.stars"
                )
                Spacer(minLength: 0)

            case .models:
                settingsItem(
                    title: "模型管理",
                    subtitle: "本机配置",
                    systemImage: "slider.horizontal.3"
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                AeroTheme.sidebarGradient
                LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.clear, AeroTheme.mint.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
        .alert(item: $agentDeleteRequest) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text("删除")) {
                    performAgentDelete(request)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var sectionPicker: some View {
        ViewThatFits(in: .horizontal) {
            sectionPickerContent(showsTitles: true)
            sectionPickerContent(showsTitles: false)
        }
        .padding(4)
        .background(Color(red: 10 / 255, green: 92 / 255, blue: 133 / 255).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func sectionPickerContent(showsTitles: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(AppSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    Group {
                        if showsTitles {
                            Label(item.displayName, systemImage: item.systemImage)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Image(systemName: item.systemImage)
                        }
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(AeroTheme.sidebarText)
                        .background(Color.white.opacity(section == item ? 0.18 : 0))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.displayName)
                .accessibilityLabel(item.displayName)
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            Image("AppMark")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("Chat")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AeroTheme.sidebarText)
                .shadow(color: Color(red: 10 / 255, green: 70 / 255, blue: 110 / 255).opacity(0.28), radius: 9, y: 4)

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var createButton: some View {
        Button(action: onCreate) {
            Label("新建聊天", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .foregroundStyle(AeroTheme.sidebarText)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("新建聊天")
    }

    private var agentActions: some View {
        HStack(spacing: 8) {
            Button(action: chooseAgentProject) {
                Label("打开项目", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .foregroundStyle(AeroTheme.sidebarText)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(agentViewModel.isRunning)

            Button(action: agentViewModel.startNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(AeroTheme.sidebarText)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(agentViewModel.isRunning || agentViewModel.selectedProjectID == nil)
            .help("在当前项目中新建会话")
        }
    }

    private var agentHistoryHeader: some View {
        HStack {
            Text("项目与会话")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AeroTheme.sidebarText.opacity(0.8))
            Spacer()
            Text("\(agentViewModel.sortedProjects.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.sidebarText.opacity(0.82))
        }
        .padding(.horizontal, 4)
    }

    private var agentProjectList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if agentViewModel.sortedProjects.isEmpty {
                    Text("打开一个本机项目后，会话历史会显示在这里。")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.sidebarText.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    ForEach(agentViewModel.sortedProjects) { project in
                        agentProjectSection(project)
                    }
                }
            }
        }
    }

    private func agentProjectSection(_ project: AgentProjectRecord) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Button {
                    agentViewModel.selectProject(project.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: agentViewModel.selectedProjectID == project.id ? "folder.fill" : "folder")
                        Text(project.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(project.sessions.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AeroTheme.sidebarText.opacity(0.62))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button("删除项目记录", systemImage: "trash", role: .destructive) {
                        agentDeleteRequest = .project(project)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("项目操作")
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(AeroTheme.sidebarText)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(Color.white.opacity(agentViewModel.selectedProjectID == project.id ? 0.17 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .disabled(agentViewModel.isRunning)
            .help(project.path)

            if agentViewModel.selectedProjectID == project.id {
                ForEach(agentViewModel.sessions(for: project.id)) { session in
                    HStack(spacing: 4) {
                        Button {
                            agentViewModel.selectSession(session.id, in: project.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(session.title)
                                        .lineLimit(1)
                                }
                                Text(session.latestPreview)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AeroTheme.sidebarText.opacity(0.58))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button("删除会话", systemImage: "trash", role: .destructive) {
                                agentDeleteRequest = .session(session, projectID: project.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("会话操作")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.sidebarText.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        Color.white.opacity(agentViewModel.selectedSessionID == session.id ? 0.16 : 0.035)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(agentViewModel.isRunning)
                    .padding(.leading, 12)
                }
            }
        }
    }

    private func chooseAgentProject() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 项目目录"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = agentViewModel.workspaceURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agentViewModel.setWorkspace(url)
    }

    private func performAgentDelete(_ request: AgentHistoryDeleteRequest) {
        switch request.kind {
        case .project:
            agentViewModel.deleteProject(request.projectID)
        case .session:
            guard let sessionID = request.sessionID else { return }
            agentViewModel.deleteSession(sessionID, in: request.projectID)
        }
    }

    private var historyHeader: some View {
        HStack {
            Text("历史记录")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AeroTheme.sidebarText.opacity(0.8))

            Spacer()

            Text("\(conversations.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.sidebarText.opacity(0.82))
                .frame(minWidth: 22, minHeight: 22)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())
        }
        .padding(.horizontal, 4)
    }

    private func settingsItem(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .opacity(0.7)
            }

            Spacer()
        }
        .foregroundStyle(AeroTheme.sidebarText)
        .padding(11)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isSelected: selection == conversation.id,
                        onSelect: { selection = conversation.id },
                        onRename: { onRename(conversation) },
                        onClear: { onClear(conversation) },
                        onDelete: { onDelete(conversation) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

private struct AgentHistoryDeleteRequest: Identifiable {
    enum Kind {
        case project
        case session
    }

    let kind: Kind
    let projectID: UUID
    let sessionID: UUID?
    let displayName: String

    var id: String {
        "\(projectID.uuidString)-\(sessionID?.uuidString ?? "project")"
    }

    var title: String {
        kind == .project ? "删除项目记录？" : "删除会话？"
    }

    var message: String {
        switch kind {
        case .project:
            "“\(displayName)”及其全部 Agent 会话记录将被永久删除，但不会删除磁盘上的项目文件。"
        case .session:
            "“\(displayName)”的 Agent 历史记录将被永久删除。"
        }
    }

    static func project(_ project: AgentProjectRecord) -> AgentHistoryDeleteRequest {
        AgentHistoryDeleteRequest(
            kind: .project,
            projectID: project.id,
            sessionID: nil,
            displayName: project.displayName
        )
    }

    static func session(
        _ session: AgentSessionRecord,
        projectID: UUID
    ) -> AgentHistoryDeleteRequest {
        AgentHistoryDeleteRequest(
            kind: .session,
            projectID: projectID,
            sessionID: session.id,
            displayName: session.title
        )
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClear: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(conversation.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(formattedTime)
                            .font(.system(size: 10))
                            .foregroundStyle(AeroTheme.sidebarText.opacity(0.64))
                    }

                    Text(conversation.latestPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.sidebarText.opacity(0.76))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("重命名", systemImage: "pencil", action: onRename)
                Button("清空对话", systemImage: "eraser", action: onClear)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(AeroTheme.sidebarText.opacity(0.82))
                    .background(Color.white.opacity(isHovering ? 0.1 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("会话操作")
        }
        .foregroundStyle(AeroTheme.sidebarText)
        .padding(10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.white.opacity(0.16)
        }
        return Color.white.opacity(isHovering ? 0.1 : 0)
    }

    private var formattedTime: String {
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            return conversation.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        return conversation.updatedAt.formatted(.dateTime.month().day())
    }
}
