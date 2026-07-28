//
//  HeyChatApp.swift
//  hey chat
//
//  Created by T L on 2026/7/24.
//

import SwiftUI
import SwiftData

@main
struct HeyChatApp: App {
    /// <#Description#>
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Conversation.self,
            ChatMessage.self,
            AIModelConfiguration.self,
            Skill.self,
            MediaRecord.self,
        ])
        let modelConfiguration = SwiftData.ModelConfiguration(
            "ChatMacData",
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1180, height: 760)
        .commands {
            HeyChatCommands()
        }
    }
}

private struct NewConversationActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newConversationAction: (() -> Void)? {
        get { self[NewConversationActionKey.self] }
        set { self[NewConversationActionKey.self] = newValue }
    }
}

private struct HeyChatCommands: Commands {
    @FocusedValue(\.newConversationAction) private var newConversationAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建聊天") {
                newConversationAction?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newConversationAction == nil)
        }

        SidebarCommands()
    }
}
