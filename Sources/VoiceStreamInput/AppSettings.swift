import Foundation

struct LLMConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
}

enum RecordingTriggerKey: String, CaseIterable {
    case rightCommand
    case function

    var title: String {
        switch self {
        case .rightCommand:
            return "Right Command"
        case .function:
            return "Fn"
        }
    }
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let recordingTriggerKey = "recordingTriggerKey"
        static let selectedLanguage = "selectedLanguage"
        static let llmEnabled = "llmEnabled"
        static let apiBaseURL = "llm.apiBaseURL"
        static let apiKey = "llm.apiKey"
        static let model = "llm.model"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.recordingTriggerKey: RecordingTriggerKey.rightCommand.rawValue,
            Key.selectedLanguage: SupportedLanguage.simplifiedChinese.rawValue,
            Key.llmEnabled: false,
            Key.apiBaseURL: "https://api.openai.com/v1",
            Key.apiKey: "",
            Key.model: "gpt-4.1-mini"
        ])
    }

    var recordingTriggerKey: RecordingTriggerKey {
        get {
            let rawValue = defaults.string(forKey: Key.recordingTriggerKey) ?? RecordingTriggerKey.rightCommand.rawValue
            return RecordingTriggerKey(rawValue: rawValue) ?? .rightCommand
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.recordingTriggerKey)
        }
    }

    var selectedLanguage: SupportedLanguage {
        get {
            let rawValue = defaults.string(forKey: Key.selectedLanguage) ?? SupportedLanguage.simplifiedChinese.rawValue
            return SupportedLanguage(rawValue: rawValue) ?? .simplifiedChinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.selectedLanguage)
        }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Key.llmEnabled) }
        set { defaults.set(newValue, forKey: Key.llmEnabled) }
    }

    var apiBaseURL: String {
        get { defaults.string(forKey: Key.apiBaseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.apiBaseURL) }
    }

    var apiKey: String {
        get { defaults.string(forKey: Key.apiKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.apiKey) }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    var llmConfigurationIfEnabled: LLMConfiguration? {
        guard llmEnabled else {
            return nil
        }

        let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !base.isEmpty,
            !key.isEmpty,
            !model.isEmpty,
            let url = URL(string: base)
        else {
            return nil
        }

        return LLMConfiguration(baseURL: url, apiKey: key, model: model)
    }
}
