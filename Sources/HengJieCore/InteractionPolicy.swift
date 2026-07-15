import CoreGraphics

public enum SelectionPhase: Sendable {
    case idle
    case selecting
    case selected
}

public enum SelectionDimmingPolicy {
    public static func shouldDim(_ phase: SelectionPhase) -> Bool { phase != .idle }
}

public enum PreviewLayout {
    public static func fitScale(imageSize: CGSize, viewportSize: CGSize, paddingFactor: CGFloat = 0.96) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height) * paddingFactor
    }
}

public enum AutomaticScrollPolicy {
    public static func shouldInject(mouseLocation: CGPoint, captureRect: CGRect) -> Bool {
        captureRect.contains(mouseLocation)
    }
}

public enum PinnedImageLayout {
    public static func fittedSize(imageSize: CGSize, availableSize: CGSize, maximumFraction: CGFloat = 0.82) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let maximum = CGSize(width: availableSize.width * maximumFraction, height: availableSize.height * maximumFraction)
        let ratio = min(1, min(maximum.width / imageSize.width, maximum.height / imageSize.height))
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }
}
