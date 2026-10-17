import Foundation

enum FileTransferPolicy {
    static func limitBytes(_ preferences: PrivacyPreferences) -> Int {
        // Imported preferences are untrusted numeric input. Clamp before
        // multiplication so a malformed backup cannot trap the application.
        min(50, max(1, preferences.maxUploadMB)) * 1024 * 1024
    }
    static func name(_ name: String, preferences: PrivacyPreferences) -> String {
        guard preferences.anonymizeFilenames else { return String(name.prefix(180)) }
        let suffix = String(URL(fileURLWithPath: name).pathExtension.prefix(12))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "File." + (suffix.isEmpty || !suffix.unicodeScalars.allSatisfy({ allowed.contains($0) }) ? "bin" : suffix)
    }
}
