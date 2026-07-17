import Foundation
import CryptoKit

/// Installs Kanban Code's non-authorizing lifecycle observer into the user
/// `~/.codex/hooks.json` layer without replacing unrelated hooks or settings.
public enum CodexHookInstaller {
    public static let eventNames = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"]

    public static func isInstalled(
        hooksPath: String? = nil,
        helperPath: String? = nil,
        expectedHelperSHA256: String? = nil
    ) -> Bool {
        let path = hooksPath ?? defaultHooksPath()
        let helper = helperPath ?? defaultHelperPath()
        guard expectedHelperSHA256.map({ helperMatches(path: helper, expectedSHA256: $0) }) ?? true,
              let root = readJSON(path: path),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let command = hookCommand(helperPath: helper)
        return eventNames.allSatisfy { eventName in
            hookEntries(in: hooks[eventName]).contains { entry in
                entry["type"] as? String == "command" && entry["command"] as? String == command
            }
        }
    }

    public static func install(hooksPath: String? = nil, helperPath: String? = nil) throws {
        let path = hooksPath ?? defaultHooksPath()
        let helper = helperPath ?? defaultHelperPath()
        try validateHelperPath(helper)
        if isInstalled(hooksPath: path, helperPath: helper) { return }

        var root = try loadJSONForMutation(path: path)
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil {
            throw CodexLifecycleInboxError.invalidEnvelope("existing Codex hooks config has an invalid hooks object")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let entry: [String: Any] = [
            "type": "command",
            "command": hookCommand(helperPath: helper),
            "timeout": 5,
            "statusMessage": "Updating Kanban Code lifecycle",
        ]

        for eventName in eventNames {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            let installed = hookEntries(in: groups).contains {
                $0["type"] as? String == "command" && $0["command"] as? String == entry["command"] as? String
            }
            guard !installed else { continue }
            if groups.isEmpty {
                groups = [["matcher": "", "hooks": [entry]]]
            } else {
                var first = groups[0]
                var entries = first["hooks"] as? [[String: Any]] ?? []
                entries.append(entry)
                first["hooks"] = entries
                groups[0] = first
            }
            hooks[eventName] = groups
        }
        root["hooks"] = hooks
        try backupExistingConfig(path: path)
        try writeJSON(root, path: path)
    }

    public static func uninstall(hooksPath: String? = nil, helperPath: String? = nil) throws {
        let path = hooksPath ?? defaultHooksPath()
        let helper = helperPath ?? defaultHelperPath()
        guard var root = readJSON(path: path),
              var hooks = root["hooks"] as? [String: Any] else { return }
        let command = hookCommand(helperPath: helper)

        for eventName in eventNames {
            guard var groups = hooks[eventName] as? [[String: Any]] else { continue }
            for index in groups.indices {
                var entries = groups[index]["hooks"] as? [[String: Any]] ?? []
                entries.removeAll {
                    $0["type"] as? String == "command" && $0["command"] as? String == command
                }
                groups[index]["hooks"] = entries
            }
            groups.removeAll { ($0["hooks"] as? [[String: Any]])?.isEmpty != false }
            if groups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = groups
            }
        }
        root["hooks"] = hooks
        try writeJSON(root, path: path)
    }

    /// Copies the code-signed app-bundled helper to the stable per-user path
    /// used by Codex hooks. This is only called from an explicit Settings action.
    @discardableResult
    public static func deployHelper(
        from bundledHelperPath: String,
        expectedSHA256: String,
        helperPath: String? = nil
    ) throws -> String {
        let destination = helperPath ?? stableHelperPath()
        try validateHelperPath(destination)
        let sourceURL = URL(fileURLWithPath: bundledHelperPath)
        guard FileManager.default.isExecutableFile(atPath: sourceURL.path) else {
            throw CodexLifecycleInboxError.invalidEnvelope("bundled lifecycle helper is missing or not executable")
        }
        let data = try Data(contentsOf: sourceURL)
        guard sha256(data) == normalizedHash(expectedSHA256) else {
            throw CodexLifecycleInboxError.invalidEnvelope("bundled lifecycle helper failed its signed hash check")
        }
        let destinationURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: destinationURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination)
        guard helperMatches(path: destination, expectedSHA256: expectedSHA256) else {
            throw CodexLifecycleInboxError.invalidEnvelope("installed lifecycle helper failed verification")
        }
        return destination
    }

    public static func sha256(path: String) throws -> String {
        sha256(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func helperMatches(path: String, expectedSHA256: String) -> Bool {
        guard let actual = try? sha256(path: path) else { return false }
        return actual == normalizedHash(expectedSHA256)
    }

    public static func stableHelperPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/bin/kanban-code-lifecycle")
    }

    private static func hookEntries(in rawGroups: Any?) -> [[String: Any]] {
        guard let groups = rawGroups as? [[String: Any]] else { return [] }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    private static func hookCommand(helperPath: String) -> String {
        // Codex's hook contract is a command string. Installation only accepts
        // a conservative absolute path alphabet, so no shell quoting or
        // interpolation is required here.
        "\(helperPath) hook-event"
    }

    private static func validateHelperPath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("//"),
              path.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 47 || byte == 95
              }) else {
            throw CodexLifecycleInboxError.invalidEnvelope("helper path must be a simple absolute path")
        }
    }

    private static func readJSON(path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    private static func loadJSONForMutation(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let root = readJSON(path: path) else {
            throw CodexLifecycleInboxError.invalidEnvelope("existing Codex hooks config is not a JSON object")
        }
        return root
    }

    private static func backupExistingConfig(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let backupURL = URL(fileURLWithPath: path + ".kanban-code.backup")
        try data.write(to: backupURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private static func writeJSON(_ root: [String: Any], path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func defaultHooksPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/hooks.json")
    }

    private static func defaultHelperPath() -> String {
        stableHelperPath()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedHash(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
