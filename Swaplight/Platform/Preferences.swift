import Foundation

@MainActor
protocol Preferences: AnyObject {
    var protections: [Protection] { get set }
    var focus: [String: Date] { get set }
    var notifications: Bool { get set }
}

@MainActor
final class LocalPreferences: Preferences {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var protections: [Protection] {
        get {
            defaults.data(forKey: "keepRunning").flatMap { try? JSONDecoder().decode([Protection].self, from: $0) } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "keepRunning") }
    }

    var focus: [String: Date] {
        get { defaults.dictionary(forKey: "observedFocus") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "observedFocus") }
    }

    var notifications: Bool {
        get { defaults.bool(forKey: "pressureNotifications") }
        set { defaults.set(newValue, forKey: "pressureNotifications") }
    }
}
