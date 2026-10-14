// swift-tools-version: 6.2
import PackageDescription

// UI-facing targets default to MainActor isolation (SpriteKit nodes are NSResponders).
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Deskterior",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Deskterior", targets: ["DeskteriorApp"]),
        .executable(name: "deskterior-assets", targets: ["DeskAssetTool"]),
    ],
    targets: [
        // Pure Swift (Foundation + simd): model, reducer, layout, pixel math, sprites-as-data,
        // 1D sims, ballistics, cloth, raster, lighting, persistence schema, demo schema.
        .target(name: "DeskCore"),
        // CoreGraphics / ImageIO / CoreText bridges: PNG, icon pixelation, Galmuri text.
        .target(name: "DeskPixels", dependencies: ["DeskCore"]),
        // Desktop mirroring and the ONLY module allowed to mutate files (FileOperator).
        .target(name: "DeskFiles", dependencies: ["DeskCore"]),
        // SpriteKit scene, presenter, frame loop, elements, input, physics.
        .target(
            name: "DeskScene",
            dependencies: ["DeskCore", "DeskPixels"],
            swiftSettings: mainActorByDefault
        ),
        // The app: windows, displays, store/effects, menus, Inventory, settings, demo runner.
        .executableTarget(
            name: "DeskteriorApp",
            dependencies: ["DeskCore", "DeskPixels", "DeskFiles", "DeskScene"],
            swiftSettings: mainActorByDefault
        ),
        // Dev tool: app icon, sprite contact sheets, fixture files.
        .executableTarget(name: "DeskAssetTool", dependencies: ["DeskCore", "DeskPixels", "DeskFiles"]),

        // DeskPixels is a test-only dependency here: PNG goldens for core rasterizers.
        .testTarget(name: "DeskCoreTests", dependencies: ["DeskCore", "DeskPixels"], exclude: ["Goldens"]),
        .testTarget(name: "DeskPixelsTests", dependencies: ["DeskCore", "DeskPixels"], exclude: ["Goldens"]),
        .testTarget(name: "DeskFilesTests", dependencies: ["DeskCore", "DeskFiles"]),
        .testTarget(
            name: "DeskSceneTests",
            dependencies: ["DeskCore", "DeskPixels", "DeskScene"],
            exclude: ["Goldens"],
            swiftSettings: mainActorByDefault
        ),
        // MARK: harden
        // The app target's pure helpers (launch options, the real-Desktop refusal, sheets, drop rules, settings, window
        // levels, the single-instance guard), through `@testable import` of the executable target.
        .testTarget(
            name: "DeskteriorAppTests",
            dependencies: ["DeskteriorApp", "DeskCore", "DeskFiles", "DeskScene"],
            swiftSettings: mainActorByDefault
        ),
    ]
)
