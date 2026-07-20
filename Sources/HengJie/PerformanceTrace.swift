import Foundation
import OSLog

enum PerformanceTrace {
    private static let signposter = OSSignposter(
        subsystem: "com.wonderlab.hengjie",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
