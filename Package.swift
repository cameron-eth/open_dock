// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fractal",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Fractal",
            path: "Sources/Fractal",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
