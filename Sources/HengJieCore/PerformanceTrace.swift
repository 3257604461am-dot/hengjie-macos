import Foundation
import OSLog

public enum PerformanceTrace {
    private static let signposter = OSSignposter(
        subsystem: "com.wonderlab.hengjie",
        category: .pointsOfInterest
    )

    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
