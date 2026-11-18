import Foundation

/// sing-box config override driven over the air: `"singbox_overrides"` in the `flags` of
/// `ui.json`, or `setSingBoxOverrides(jsonString)` called from `logic.js` (both end in
/// `OTAManager`, which calls `OTAOverrides.store`). `SingBoxConfigBuilder.build` deep-merges the
/// stored object onto the generated config right before it is serialised and written to disk.
/// Thread-safe side of the sing-box override: reads the stored JSON and deep-merges it.
enum OTAOverrides {
    static let storageKey = "ota.singboxOverrides"

    /// Stores the override JSON (an object) that `apply(to:)` merges into every generated
    /// config. An empty string, `{}` or `null` clears it. Returns false and keeps the old value
    /// when `json` is not a JSON object. Safe to call from any thread.
    @discardableResult
    static func store(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" || trimmed == "null" {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else { return false }
        UserDefaults.standard.set(trimmed, forKey: storageKey)
        return true
    }

    /// The raw stored override text, for change detection.
    static var storedText: String? { UserDefaults.standard.string(forKey: storageKey) }

    /// Keys an override may never touch: the loopback / share listeners (the `mixed-in` port the
    /// cellular profile points at) and the Clash API the app polls.
    private static let protectedTopLevel: Set<String> = ["inbounds"]

    static func stored() -> [String: Any]? {
        guard let text = UserDefaults.standard.string(forKey: storageKey),
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
