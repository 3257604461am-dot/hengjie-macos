// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HengJie",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HengJieCore", targets: ["HengJieCore"]),
        .executable(name: "HengJie", targets: ["HengJie"]),
        .executable(name: "HengJieCoreChecks", targets: ["HengJieCoreChecks"])
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
        .executableTarget(
            name: "HengJie",
            dependencies: ["HengJieCore"],
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
        .executableTarget(name: "HengJieCoreChecks", dependencies: ["HengJieCore"])
    ],
    swiftLanguageModes: [.v5]
)
