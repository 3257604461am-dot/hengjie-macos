import Foundation

public enum CaptureSessionState: String, Sendable {
    case idle, selecting, capturing, editing, completed, cancelled, failed
}

public struct CaptureSessionToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

@MainActor
public final class CaptureSessionRegistry {
    public private(set) var state: CaptureSessionState = .idle
    public private(set) var current: CaptureSessionToken?
    public var onTransition: ((CaptureSessionToken, CaptureSessionState) -> Void)?

    public init() {}

    public func begin(_ initialState: CaptureSessionState = .selecting) -> CaptureSessionToken {
        let token = CaptureSessionToken(id: UUID())
        current = token
        state = initialState
        onTransition?(token, initialState)
        return token
    }

    @discardableResult
    public func transition(_ next: CaptureSessionState, for token: CaptureSessionToken) -> Bool {
        guard current == token else { return false }
        state = next
        onTransition?(token, next)
        return true
    }

    public func finish(_ token: CaptureSessionToken, state finalState: CaptureSessionState = .completed) {
        guard current == token else { return }
        state = finalState
        onTransition?(token, finalState)
        current = nil
        state = .idle
    }

    public func isCurrent(_ token: CaptureSessionToken) -> Bool { current == token }
}
