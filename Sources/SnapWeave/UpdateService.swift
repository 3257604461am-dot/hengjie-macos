import AppKit

enum UpdateServiceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "当前构建未启用自动更新，请从 GitHub Releases 手动下载新版本。"
    }
}

@MainActor
protocol UpdateService: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates() throws
}

@MainActor
final class DisabledUpdateService: UpdateService {
    let isAvailable = false
    func checkForUpdates() throws { throw UpdateServiceError.unavailable }
}

#if canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleUpdateService: UpdateService {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }
    func checkForUpdates() throws {
        guard isAvailable else { throw UpdateServiceError.unavailable }
        controller.checkForUpdates(nil)
    }
}
#endif

@MainActor
enum UpdateServiceFactory {
    static func make() -> UpdateService {
        #if canImport(Sparkle)
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil { return SparkleUpdateService() }
        #endif
        return DisabledUpdateService()
    }
}
