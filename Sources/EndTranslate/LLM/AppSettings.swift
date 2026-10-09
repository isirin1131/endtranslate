import Foundation
import Security

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var apiKey: String { didSet { Keychain.write(account: "apiKey", value: apiKey) } }

    struct Preset: Identifiable {
        let name: String
        let baseURL: String
        let model: String
        var id: String { name }
    }

    static let presets = [
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o"),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash")
    ]

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1"
        model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o"
        apiKey = Keychain.read(account: "apiKey") ?? ""
    }

    /// Local servers (Ollama, LM Studio…) usually run without a key.
    var isLocalEndpoint: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var isConfigured: Bool {
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (hasKey || isLocalEndpoint)
    }

    func apply(_ preset: Preset) {
        baseURL = preset.baseURL
        model = preset.model
    }

    /// `swift run` stores defaults under the executable name; the .app bundle under its
    /// bundle id. Carry settings and reading history over the first time the bundle runs.
    static func migrateLegacyDefaults() {
        let legacyDomain = "EndTranslate"
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != legacyDomain,
              UserDefaults.standard.object(forKey: "baseURL") == nil,
              let legacy = UserDefaults.standard.persistentDomain(forName: legacyDomain) else { return }
        for key in ["baseURL", "model", "recentFiles", "readingPositions"] {
            if let value = legacy[key] { UserDefaults.standard.set(value, forKey: key) }
        }
        Log.write("migrated defaults from \(legacyDomain)")
    }
}

enum Keychain {
    private static let service = "app.endtranslate"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func write(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
