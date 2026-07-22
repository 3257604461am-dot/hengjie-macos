import Foundation

public enum AppStorageMigrationResult: Equatable, Sendable {
    case notNeeded
    case usingCurrent
    case migrated
    case bothPresent
    case failed(String)
}

public enum AppStoragePaths {
    public static let currentDirectoryName = "SnapWeave"
    public static let legacyDirectoryName = "横截"

    public static var root: URL {
        root(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    public static func root(in applicationSupportURL: URL) -> URL {
        applicationSupportURL.appendingPathComponent(currentDirectoryName, isDirectory: true)
    }

    public static func legacyRoot(in applicationSupportURL: URL) -> URL {
        applicationSupportURL.appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }

    /// Moves the complete legacy data directory before any service opens files in it.
    /// A failed move leaves the legacy directory untouched for a future retry.
    public static func prepare(
        in applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> AppStorageMigrationResult {
        prepare(in: applicationSupportURL, fileManager: fileManager) { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func prepare(
        in applicationSupportURL: URL?,
        fileManager: FileManager,
        moveItem: (URL, URL) throws -> Void
    ) -> AppStorageMigrationResult {
        let support = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = root(in: support)
        let legacy = legacyRoot(in: support)
        let currentExists = fileManager.fileExists(atPath: current.path)
        let legacyExists = fileManager.fileExists(atPath: legacy.path)

        if currentExists && legacyExists { return .bothPresent }
        if currentExists { return .usingCurrent }
        guard legacyExists else { return .notNeeded }

        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try moveItem(legacy, current)
            return .migrated
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
