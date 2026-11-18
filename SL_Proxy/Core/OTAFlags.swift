import Foundation
import Combine

/// Over-the-air UI flags (`"flags"` object of `ui.json`) and the optional sing-box config override.
///
/// This zip has no JavaScriptCore runner, so this file is the Swift side the runner plugs into:
/// - the runner (or any fetcher of `ui.json`) calls `OTAFlags.shared.apply(uiJSON:)` or
///   `apply(flags:)` with the parsed `flags` dictionary;
/// - `getFlag` / `setFlag` bridge functions read and write `OTAFlags.shared.value(for:)` /
///   `set(_:for:)`;
/// - `setSingBoxOverrides(jsonString)` on the JS side calls `OTAFlags.shared.setSingBoxOverrides(_:)`.
///
/// Known flags: `hide_home_chart` (Bool, default true), `default_home_layout` (String, one of
/// `classic`, `tactical`, `telemetry`, `terminal`) and `singbox_overrides` (object or JSON string).
@MainActor
final class OTAFlags: ObservableObject {
    static let shared = OTAFlags()

    /// Bumped on every change so SwiftUI views observing the object re-evaluate their flags.
    @Published private(set) var revision = 0

    private var flags: [String: Any] = [:]

    private init() {
        if let text = UserDefaults.standard.string(forKey: Keys.flags),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            flags = object
        }
    }

    enum Keys {
        static let flags = "ota_flags_json"
        /// Read from any thread by `OTAOverrides`.
        static let singBoxOverrides = "ota_singbox_overrides_json"
    }

    // MARK: - Reading

    func value(for key: String) -> Any? { flags[key] }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        if let value = flags[key] as? Bool { return value }
        if let number = flags[key] as? NSNumber { return number.boolValue }
        if let text = (flags[key] as? String)?.lowercased() {
            if text == "true" || text == "1" { return true }
            if text == "false" || text == "0" { return false }
        }
        return fallback
    }

    func string(_ key: String) -> String? { flags[key] as? String }

    /// OTA switch for the live traffic chart card on Home. Hidden unless `hide_home_chart` is false.
    var hidesHomeChart: Bool { bool("hide_home_chart", default: true) }

    /// Layout the OTA config suggests until the user picks one (`default_home_layout`).
    var defaultHomeLayout: String? { string("default_home_layout") }

    // MARK: - Writing

    func set(_ value: Any?, for key: String) {
        var updated = flags
        updated[key] = value
        replace(with: updated)
    }

    /// Merges a parsed `flags` object into the stored flags. Keys absent from `incoming` keep
    /// their last value; send `null` to clear one.
    func apply(flags incoming: [String: Any]) {
        var updated = flags
        for (key, value) in incoming {
            if value is NSNull { updated[key] = nil } else { updated[key] = value }
        }
        replace(with: updated)
        if let overrides = incoming["singbox_overrides"] {
            applyOverrides(overrides)
        }
    }

    /// Parses a whole `ui.json` body and applies its `"flags"` object. False when it is not JSON.
    @discardableResult
    func apply(uiJSON data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let incoming = root["flags"] as? [String: Any] { apply(flags: incoming) }
        return true
    }

    /// `setSingBoxOverrides(jsonString)`: stores a JSON object that is deep-merged onto the
    /// generated sing-box config. Returns false (and keeps the old value) when the string is not a
    /// JSON object. An empty string or `{}` clears the override.
    @discardableResult
    func setSingBoxOverrides(_ jsonString: String) -> Bool {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" || trimmed == "null" {
            UserDefaults.standard.removeObject(forKey: Keys.singBoxOverrides)
            bump()
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        UserDefaults.standard.set(trimmed, forKey: Keys.singBoxOverrides)
        _ = object
        bump()
        return true
    }

    // MARK: - Private

    private func applyOverrides(_ raw: Any) {
        if let text = raw as? String {
            setSingBoxOverrides(text)
        } else if let object = raw as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) {
            setSingBoxOverrides(text)
        } else if raw is NSNull {
            setSingBoxOverrides("")
        }
    }

    private func replace(with updated: [String: Any]) {
        flags = updated
        if JSONSerialization.isValidJSONObject(updated),
           let data = try? JSONSerialization.data(withJSONObject: updated),
           let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: Keys.flags)
        }
        bump()
    }

    private func bump() { revision += 1 }
}

/// Thread-safe side of the sing-box override: reads the stored JSON and deep-merges it.
enum OTAOverrides {
    /// Keys an override may never touch: the loopback / share listeners (the `mixed-in` port the
    /// cellular profile points at) and the Clash API the app polls.
    private static let protectedTopLevel: Set<String> = ["inbounds"]

    static func stored() -> [String: Any]? {
        guard let text = UserDefaults.standard.string(forKey: OTAFlags.Keys.singBoxOverrides),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return nil }
        return sanitized(object)
    }

    /// Returns `config` with the stored override merged in; `config` itself when there is none or
    /// the merged result is not valid JSON.
    static func apply(to config: [String: Any]) -> [String: Any] {
        guard let overrides = stored() else { return config }
        let merged = deepMerge(config, overrides)
        return JSONSerialization.isValidJSONObject(merged) ? merged : config
    }

    /// Objects merge key by key; any other value (arrays included) replaces the base value.
    static func deepMerge(_ base: [String: Any], _ overrides: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overrides {
            if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = deepMerge(existing, nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func sanitized(_ object: [String: Any]) -> [String: Any] {
        var clean = object.filter { !protectedTopLevel.contains($0.key) }
        if var experimental = clean["experimental"] as? [String: Any] {
            experimental["clash_api"] = nil
            clean["experimental"] = experimental
        }
        return clean
    }
}
