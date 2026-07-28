import Foundation

struct AgentPersonalPreferencesStore {
    private let defaults: UserDefaults
    private let storageKey = "agent.personal-preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AgentPersonalPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(AgentPersonalPreferences.self, from: data) else {
            return AgentPersonalPreferences()
        }
        return preferences
    }

    func save(_ preferences: AgentPersonalPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
