import Foundation
import Security
import SpatialApple

/// The backend address is a preference. Its local session credential belongs in Keychain.
struct SessionConfigurationStore {
    struct Values {
        var backendURL: String
        var token: String
    }

    private let defaults = UserDefaults.standard
    private let addressKey = "astra.session.backendURL"
    private let keychainService = "com.astra.spatialdemo.session"

    func load() -> Values {
        #if targetEnvironment(simulator)
        let fallback = "http://127.0.0.1:8787"
        #else
        // Loopback on a phone points at the phone, not the development Mac.
        let fallback = ""
        #endif
        var address = defaults.string(forKey: addressKey) ?? fallback
        var source = defaults.string(forKey: addressKey) == nil ? "platform_default" : "saved"
        var injectedToken: String?
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let injectedAddress = environment["ASTRA_BACKEND_URL"] {
            address = injectedAddress
            injectedToken = environment["ASTRA_SESSION_TOKEN"]
            source = "launch_environment"
        }
        #endif
        let account = (try? BackendConnectionConfiguration(address: address, token: "").url.absoluteString) ?? address
        let values = Values(backendURL: address, token: injectedToken ?? readToken(account: account))
        DiagnosticsLog.shared.record("configuration.loaded", component: "app", fields: [
            "source": source,
            "host": URL(string: address)?.host ?? "unset",
            "authenticated_configuration": String(!values.token.isEmpty),
        ])
        if let configuration = try? BackendConnectionConfiguration(address: values.backendURL, token: values.token) {
            // Launch-time development configuration must survive an ordinary icon launch.
            save(configuration)
        }
        return values
    }

    func save(_ configuration: BackendConnectionConfiguration) {
        let account = configuration.url.absoluteString
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        let status: OSStatus
        if configuration.token.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let data = Data(configuration.token.utf8)
            let update: [CFString: Any] = [kSecValueData: data]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query
                item[kSecValueData] = data
                item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        guard status == errSecSuccess || (configuration.token.isEmpty && status == errSecItemNotFound) else {
            DiagnosticsLog.shared.record("configuration.save_failed", component: "app", level: .warning,
                                         fields: ["keychain_status": String(status)])
            return
        }
        defaults.set(account, forKey: addressKey)
    }

    private func readToken(account: String) -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct BackendConnectionConfiguration: Equatable {
    let url: URL
    let token: String

    init(address: String, token: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw ConfigurationError.missingAddress }
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalidAddress
        }
        #if !targetEnvironment(simulator)
        guard !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
            throw ConfigurationError.deviceLoopback
        }
        #endif
        self.url = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ConfigurationError: LocalizedError {
        case missingAddress, invalidAddress, deviceLoopback

        var errorDescription: String? {
            switch self {
            case .missingAddress: "This device needs the session server address. Add it in settings."
            case .invalidAddress: "Enter a valid http or https server address in settings."
            case .deviceLoopback: "Use the Mac’s network address in settings so this device can reach Astra."
            }
        }
    }
}
