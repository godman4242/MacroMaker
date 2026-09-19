import Foundation
import os

/// Tiny Codable wrapper around UserDefaults for settings structs.
enum Persistence {
    private static let log = Logger(subsystem: "MacroMaker", category: "Persistence")

    /// Where saves land. A seam for tests: install a failing writer to exercise the failure
    /// paths callers must surface — production writes to UserDefaults, which reports no
    /// failure of its own.
    nonisolated(unsafe) static var writer: @Sendable (_ data: Data, _ key: String) -> Bool = { data, key in
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Returns whether the write landed. A silent `try?` here made a failed save
    /// indistinguishable from success — the caller must be able to warn the user.
    @discardableResult
    static func save<Value: Encodable>(_ value: Value, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else {
            log.fault("Couldn't encode the value for key “\(key, privacy: .public)” — the save was dropped.")
            return false
        }
        let landed = writer(data, key)
        if !landed {
            log.fault("The write for key “\(key, privacy: .public)” failed — the save was dropped.")
        }
        return landed
    }
}
