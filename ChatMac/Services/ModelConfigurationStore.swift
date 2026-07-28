import Foundation

enum ModelConfigurationStore {
    static func normalizeDefaults(
        in models: [AIModelConfiguration],
        preferredID: UUID? = nil
    ) {
        for category in AIModelCategory.allCases {
            let categoryModels = models.filter {
                $0.hasSupportedCategory && $0.category == category
            }
            let enabledModels = sorted(categoryModels.filter(\.isEnabled))
            let preferred = enabledModels.first(where: { $0.id == preferredID })
                ?? enabledModels.first(where: \.isDefault)
                ?? enabledModels.first

            for model in categoryModels {
                let shouldBeDefault = model.id == preferred?.id
                if model.isDefault != shouldBeDefault {
                    model.isDefault = shouldBeDefault
                }
            }
        }
    }

    static func preferredChatModel(
        selected: AIModelConfiguration?,
        from models: [AIModelConfiguration]
    ) -> AIModelConfiguration? {
        let available = sorted(models.filter {
            $0.isEnabled && $0.hasSupportedCategory && $0.category == .chat
        })
        if let selected,
           available.contains(where: { $0.id == selected.id }) {
            return selected
        }
        return available.first(where: \.isDefault) ?? available.first
    }

    static func preferredModel(
        in category: AIModelCategory,
        selectedID: UUID?,
        from models: [AIModelConfiguration]
    ) -> AIModelConfiguration? {
        let available = sorted(models.filter {
            $0.isEnabled
                && $0.hasSupportedCategory
                && $0.category == category
                && $0.provider == .openAICompatible
        })
        if let selectedID,
           let selected = available.first(where: { $0.id == selectedID }) {
            return selected
        }
        return available.first(where: \.isDefault) ?? available.first
    }

    static func sorted(_ models: [AIModelConfiguration]) -> [AIModelConfiguration] {
        models.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault
            }
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func migrateLegacyConfigurations(in models: [AIModelConfiguration]) {
        for model in models where ["openRouter", "ollama"].contains(model.providerRawValue) {
            model.provider = .openAICompatible
        }

        for model in models where model.category == .agent {
            let storedEngine = model.agentEngineRawValue.flatMap(AgentEngineKind.init(rawValue:))
            let engine = storedEngine.flatMap {
                AgentEngineKind.configurationChannels.contains($0) ? $0 : nil
            } ?? (model.provider == .anthropicCompatible ? .claudeCodeCLI : .codexCLI)

            if storedEngine != engine {
                model.agentEngine = engine
            }

            let storedAPI = model.agentAPIKindRawValue.flatMap(AgentAPIKind.init(rawValue:))
            if storedAPI.map({ engine.supportedAPIs.contains($0) }) != true {
                model.agentAPIKindRawValue = engine.supportedAPIs.first?.rawValue
            }

            if model.agentCredentialRawValue != "apiKey" {
                model.agentCredentialRawValue = "apiKey"
            }

            let storedEffort = model.agentReasoningEffortRawValue
                .flatMap(AgentReasoningEffort.init(rawValue:))
            if storedEffort.map({ engine.supportedReasoningEfforts.contains($0) }) != true {
                model.agentReasoningEffort = .automatic
            }

            let channelName = model.channelName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if channelName.isEmpty {
                model.channelName = engine.channelDisplayName
            }
        }
    }
}
