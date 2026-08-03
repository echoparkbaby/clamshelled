import Foundation

/// Persisted preferences. Plain UserDefaults — nothing here is a secret, and the
/// system already handles the file, the migration and the flushing.
@MainActor
enum Settings {
    private static let store = UserDefaults.standard

    private enum Key {
        static let keepAwakeAtLaunch = "KeepAwakeAtLaunch"
        static let tintWhenKeepAwake = "TintIconWhenKeepAwake"
        static let autoOffMinutes    = "ClamshellAutoOffMinutes"
    }

    /// Call once at launch, before anything reads a value.
    static func registerDefaults() {
        store.register(defaults: [
            Key.keepAwakeAtLaunch: false,   // opt-in: don't change sleep behaviour uninvited
            Key.tintWhenKeepAwake: true,
            Key.autoOffMinutes: 0,          // 0 = never
        ])
    }

    static var keepAwakeAtLaunch: Bool {
        get { store.bool(forKey: Key.keepAwakeAtLaunch) }
        set { store.set(newValue, forKey: Key.keepAwakeAtLaunch) }
    }

    static var tintWhenKeepAwake: Bool {
        get { store.bool(forKey: Key.tintWhenKeepAwake) }
        set { store.set(newValue, forKey: Key.tintWhenKeepAwake) }
    }

    /// Minutes after which lid-closed mode turns itself off. 0 = never.
    static var autoOffMinutes: Int {
        get { store.integer(forKey: Key.autoOffMinutes) }
        set { store.set(newValue, forKey: Key.autoOffMinutes) }
    }

    /// Menu titles and their stored values, in display order.
    static let autoOffChoices: [(title: String, minutes: Int)] = [
        ("Never", 0),
        ("After 1 hour", 60),
        ("After 2 hours", 120),
        ("After 4 hours", 240),
        ("After 8 hours", 480),
    ]
}
