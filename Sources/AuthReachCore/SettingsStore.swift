import Foundation

/// Settings persisted as JSON in Application Support (non-secret material
/// only — credentials and tokens live in the Keychain).
public final class SettingsStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "settings-store")
    private var cache: Settings?

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "settings.json")
    }

    public static func standard() -> SettingsStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AuthReach")
        return SettingsStore(directory: dir)
    }

    public func load() -> Settings {
        queue.sync {
            if let cache { return cache }
            let settings = (try? Data(contentsOf: fileURL))
                .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? .defaults
            cache = settings
            return settings
        }
    }

    public func save(_ settings: Settings) throws {
        try queue.sync {
            cache = settings
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (try encoder.encode(settings)).write(to: fileURL, options: .atomic)
        }
    }

    public func update(_ mutate: (inout Settings) -> Void) throws -> Settings {
        var settings = load()
        mutate(&settings)
        try save(settings)
        return settings
    }
}
