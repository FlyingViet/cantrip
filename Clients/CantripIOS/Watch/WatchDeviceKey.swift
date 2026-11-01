import CryptoKit
import Foundation
import Security

/// Signs watch requests. The private key never leaves the watch.
protocol CantripDeviceSigner {
    /// Uncompressed public key (65 bytes), as registered with the Mac.
    var publicKeyX963: Data { get }
    /// DER signature of `message` (ECDSA P-256 with SHA-256).
    func signature(for message: Data) throws -> Data
}

extension CantripDeviceSigner {
    var publicKeyBase64: String { publicKeyX963.base64EncodedString() }
}

struct SoftwareDeviceSigner: CantripDeviceSigner {
    let key: P256.Signing.PrivateKey

    var publicKeyX963: Data { key.publicKey.x963Representation }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

struct SecureEnclaveDeviceSigner: CantripDeviceSigner {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyX963: Data { key.publicKey.x963Representation }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

/// The watch's device key, kept in this watch's keychain only (never synced or backed up).
/// Secure Enclave on a real watch; a software key in the simulator or without one.
enum WatchDeviceKey {
    private static let service = "Cantrip Watch"
    private static let secureEnclaveAccount = "device-key.secure-enclave"
    private static let softwareAccount = "device-key.software"

    private static var usesSecureEnclave: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclave.isAvailable
        #endif
    }

    /// The saved key, or a new one saved now.
    static func loadOrCreate() throws -> CantripDeviceSigner {
        if let data = try read(secureEnclaveAccount) {
            return SecureEnclaveDeviceSigner(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
        }
        if let data = try read(softwareAccount) {
            return SoftwareDeviceSigner(key: try P256.Signing.PrivateKey(rawRepresentation: data))
        }
        if usesSecureEnclave {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
            ) else {
                throw error?.takeRetainedValue() ?? CantripWatchError.failed("The watch couldn't create its key.")
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try save(key.dataRepresentation, account: secureEnclaveAccount)
            return SecureEnclaveDeviceSigner(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try save(key.rawRepresentation, account: softwareAccount)
        return SoftwareDeviceSigner(key: key)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CantripWatchError.failed("The watch couldn't read its key (error \(status)).")
        }
        return data
    }

    private static func save(_ data: Data, account: String) throws {
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CantripWatchError.failed("The watch couldn't save its key (error \(status)).")
        }
    }
}
