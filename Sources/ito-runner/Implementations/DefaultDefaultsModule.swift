import Foundation

/// The default implementation of `DefaultsModule`, using `UserDefaults`.
public final class DefaultDefaultsModule: DefaultsModule, @unchecked Sendable {

    private let defaults: UserDefaults
    private let pluginId: String

    /// Initializes a generic defaults store, namespaced by plugin ID.
    public init(pluginId: String) {
        self.pluginId = pluginId
        // Ideally use a suite name to isolate from the main host app defaults
        self.defaults = UserDefaults(suiteName: "moe.ito.runners.\(pluginId)") ?? .standard
    }

    public func set(key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    /// The standalone runner has no secure store: tokens are kept like any other value.
    public func setSecret(key: String, value: String) {
        set(key: key, value: value)
    }

    public func get(key: String) -> String? {
        return defaults.string(forKey: key)
    }

    public func remove(key: String) {
        defaults.removeObject(forKey: key)
    }
}
