import CryptoKit
import Foundation
import Network
import Security

enum RemoteLANProtocol {
    static let serviceType = "_cantrip-remote._tcp"

    static func parameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let derivedKey = Data(SHA256.hash(data: Data(token.utf8)))
        let key = derivedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("cantrip-remote-v1".utf8).withUnsafeBytes {
            DispatchData(bytes: $0)
        }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            key as dispatch_data_t,
            identity as dispatch_data_t
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(
                rawValue: UInt16(TLS_DHE_PSK_WITH_AES_128_GCM_SHA256)
            )!
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
