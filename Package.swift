// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapWeave",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapWeaveCore", targets: ["SnapWeaveCore"]),
        .library(name: "SnapWeaveCapture", targets: ["SnapWeaveCapture"]),
        .library(name: "SnapWeaveAnnotation", targets: ["SnapWeaveAnnotation"]),
        .library(name: "SnapWeaveHistory", targets: ["SnapWeaveHistory"]),
        .library(name: "SnapWeaveMedia", targets: ["SnapWeaveMedia"]),
        .executable(name: "SnapWeave", targets: ["SnapWeave"]),
        .executable(name: "SnapWeaveCoreChecks", targets: ["SnapWeaveCoreChecks"]),
        .executable(name: "SnapWeaveArchitectureChecks", targets: ["SnapWeaveArchitectureChecks"])
    ],
    targets: [
        .target(
            name: "SnapWeaveCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ImageIO"),
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .target(
            name: "SnapWeaveCapture",
            dependencies: ["SnapWeaveCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "SnapWeaveAnnotation",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "SnapWeaveHistory",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SnapWeaveMedia",
            dependencies: ["SnapWeaveCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "SnapWeave",
            dependencies: ["SnapWeaveCore", "SnapWeaveCapture", "SnapWeaveAnnotation", "SnapWeaveHistory", "SnapWeaveMedia"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(name: "SnapWeaveCoreChecks", dependencies: ["SnapWeaveCore"]),
        .executableTarget(
            name: "SnapWeaveArchitectureChecks",
            dependencies: ["SnapWeaveAnnotation", "SnapWeaveCapture", "SnapWeaveHistory"]
        ),
        .testTarget(name: "SnapWeaveCoreTests", dependencies: ["SnapWeaveCore"])
    ],
    swiftLanguageModes: [.v5]
)
