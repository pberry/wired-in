import Foundation
import Security

/// Something to notify when the active preset changes.
public protocol StatusIntegration: Sendable {
    var name: String { get }
    func request(for preset: Preset?) -> URLRequest?
    /// Checks a 2xx response body for service-level errors.
    func validate(_ data: Data) throws
}

extension StatusIntegration {
    /// Sends the update. `nil` preset means the sign was turned off.
    public func publish(_ preset: Preset?, session: URLSession = .shared) async throws {
        guard let request = request(for: preset) else { return }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SignError.io("\(name) returned an error: \(String(decoding: data, as: UTF8.self))")
        }
        try validate(data)
    }

    public func validate(_ data: Data) throws {}
}

/// Sets your Slack profile status with a user token (`xoxp-…`) that has the
/// `users.profile:write` scope. The original app's OAuth relay no longer exists,
/// so you create your own Slack app and paste its token.
public struct SlackIntegration: StatusIntegration {
    public let name = "Slack"
    public var token: String

    public init(token: String) { self.token = token }

    public func request(for preset: Preset?) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://slack.com/api/users.profile.set")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let profile: [String: Any] = [
            "status_text": preset?.name ?? "",
            "status_emoji": preset?.slackEmoji ?? "",
            "status_expiration": 0,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["profile": profile], options: .sortedKeys)
        return request
    }

    public func validate(_ data: Data) throws {
        // Slack returns HTTP 200 with {"ok": false, "error": "..."} on failure.
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if body?["ok"] as? Bool != true {
            throw SignError.io("Slack: \(body?["error"] as? String ?? "unknown error")")
        }
    }
}

/// IFTTT Webhooks. `value1` = preset name, `value2` = emoji, `value3` = hex color.
public struct IFTTTIntegration: StatusIntegration {
    public let name = "IFTTT"
    public var key: String
    public var event: String

    public init(key: String, event: String) {
        self.key = key
        self.event = event
    }

    public func request(for preset: Preset?) -> URLRequest? {
        let event = event.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !event.isEmpty,
              let encodedEvent = event.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://maker.ifttt.com/trigger/\(encodedEvent)/with/key/\(key)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let values = [
            "value1": preset?.name ?? "Off",
            "value2": preset?.emoji ?? "",
            "value3": preset?.color.hex ?? "",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        return request
    }
}

/// Minimal generic-password Keychain wrapper for integration secrets.
public enum Keychain {
    static let service = "com.wiredin.WiredIn"

    public static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
