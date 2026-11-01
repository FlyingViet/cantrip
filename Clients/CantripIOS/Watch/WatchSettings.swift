import Foundation

/// Where this watch reaches its Mac, saved after setup. Nothing here is secret: requests are
/// signed with the device key, which stays in the keychain.
struct CantripWatchConfiguration: Equatable {
    var deviceID: String
    var tailnet: URL
    var internet: URL?
    var serverName: String?
}

enum WatchSettings {
    private static let deviceIDKey = "cantrip.watch.deviceID"
    private static let tailnetKey = "cantrip.watch.tailnet"
    private static let internetKey = "cantrip.watch.internet"
    private static let serverKey = "cantrip.watch.server"
    private static let lastRouteKey = "cantrip.watch.lastRoute"
    static let speakRepliesKey = "cantrip.watch.speakReplies"

    private static var defaults: UserDefaults { .standard }

    static var configuration: CantripWatchConfiguration? {
        #if DEBUG
        if let qa = WatchQA.current { return qa.configuration }
        #endif
        guard let deviceID = defaults.string(forKey: deviceIDKey), !deviceID.isEmpty,
              let tailnet = CantripWatchURL.origin(defaults.string(forKey: tailnetKey))
        else { return nil }
        return CantripWatchConfiguration(
            deviceID: deviceID,
            tailnet: tailnet,
            internet: CantripWatchURL.origin(defaults.string(forKey: internetKey)),
            serverName: defaults.string(forKey: serverKey)
        )
    }

    static func save(_ configuration: CantripWatchConfiguration) {
        defaults.set(configuration.deviceID, forKey: deviceIDKey)
        defaults.set(configuration.tailnet.absoluteString, forKey: tailnetKey)
        defaults.set(configuration.internet?.absoluteString, forKey: internetKey)
        defaults.set(configuration.serverName, forKey: serverKey)
        defaults.removeObject(forKey: lastRouteKey)
    }

    static func clear() {
        for key in [deviceIDKey, tailnetKey, internetKey, serverKey, lastRouteKey] {
            defaults.removeObject(forKey: key)
        }
    }

    static func saveInternet(_ url: URL?) {
        #if DEBUG
        if WatchQA.current != nil { return }
        #endif
        defaults.set(url?.absoluteString, forKey: internetKey)
    }

    static var lastRoute: CantripWatchRoute? {
        get { defaults.string(forKey: lastRouteKey).flatMap(CantripWatchRoute.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: lastRouteKey) }
    }

    static var speakReplies: Bool {
        get { defaults.object(forKey: speakRepliesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: speakRepliesKey) }
    }

    static func signer() throws -> CantripDeviceSigner {
        #if DEBUG
        if let qa = WatchQA.current { return qa.signer }
        #endif
        return try WatchDeviceKey.loadOrCreate()
    }
}
