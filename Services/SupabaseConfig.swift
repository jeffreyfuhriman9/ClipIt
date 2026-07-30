import Foundation

enum SupabaseConfig {
    static let redirectURL = URL(string: "clipit://login-callback")!

    static var url: URL? {
        guard let string = secret(for: "SUPABASE_URL"),
              let url = URL(string: string) else { return nil }
        return url
    }

    static var anonKey: String? {
        secret(for: "SUPABASE_ANON_KEY")
    }

    static var isConfigured: Bool {
        url != nil && anonKey != nil
    }

    private static func secret(for key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let value = dict[key] as? String,
              !value.isEmpty,
              !value.hasPrefix("YOUR_") else {
            return nil
        }
        return value
    }
}
