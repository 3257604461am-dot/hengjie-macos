// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HengJie",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HengJieCore", targets: ["HengJieCore"]),
        .library(name: "HengJieCapture", targets: ["HengJieCapture"]),
        .library(name: "HengJieAnnotation", targets: ["HengJieAnnotation"]),
        .library(name: "HengJieHistory", targets: ["HengJieHistory"]),
        .library(name: "HengJieMedia", targets: ["HengJieMedia"]),
        .executable(name: "HengJie", targets: ["HengJie"]),
        .executable(name: "HengJieCoreChecks", targets: ["HengJieCoreChecks"]),
        .executable(name: "HengJieArchitectureChecks", targets: ["HengJieArchitectureChecks"])
    ],
    targets: [
        .target(
            name: "HengJieCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ImageIO"),
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .target(
            name: "HengJieCapture",
            dependencies: ["HengJieCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "HengJieAnnotation",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(
            name: "HengJieHistory",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HengJieMedia",
            dependencies: ["HengJieCore"],
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
            name: "HengJie",
            dependencies: ["HengJieCore", "HengJieCapture", "HengJieAnnotation", "HengJieHistory", "HengJieMedia"],
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
        .executableTarget(name: "HengJieCoreChecks", dependencies: ["HengJieCore"]),
        .executableTarget(
            name: "HengJieArchitectureChecks",
            dependencies: ["HengJieAnnotation", "HengJieCapture", "HengJieHistory"]
        ),
        .testTarget(name: "HengJieCoreTests", dependencies: ["HengJieCore"])
    ],
    swiftLanguageModes: [.v5]
)
