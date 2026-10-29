// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Riffle",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Riffle", targets: ["Riffle"]),
    ],
    dependencies: [
        // Updates: checks appriffle.com/updates/appcast.xml, installs what Riffle's key signed. Scripts/build.sh puts
        // the framework in the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Riffle",
            dependencies: ["CrashGuardCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Riffle",
            linkerSettings: [
                // Sparkle.framework sits in the app's Contents/Frameworks (Scripts/build.sh puts it there).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // What runs inside a crash handler, in C: Swift can't promise a handler that never allocates, locks or calls into
        // its runtime.
        .target(
            name: "CrashGuardCore",
            path: "Sources/CrashGuardCore",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        // Crashes on purpose, for CrashGuardTests. Not part of the app.
        .executableTarget(
            name: "CrashGuardProbe",
            dependencies: ["CrashGuardCore"],
            path: "Tests/CrashGuardProbe"
        ),
        .testTarget(
            name: "RiffleTests",
            dependencies: ["Riffle", "CrashGuardProbe"],
            path: "Tests/RiffleTests"
        ),
    ],
    // AppKit, Carbon and AX callbacks are C-shaped and main-thread bound; Swift 6's strict
    // concurrency checking adds noise there without catching real bugs, so we stay in Swift 5 mode.
    swiftLanguageModes: [.v5]
)
