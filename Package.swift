// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReSign",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ReSign", targets: ["ReSign"])],
    dependencies: [
        .package(path: "Vendor/SideSign"),
        .package(path: "Vendor/MobileDevice"),
        .package(url: "https://github.com/mahee96/AnisetteKit.git", revision: "db8b41022697b6c19be8a5f01a1ce834145a2a26")
    ],
    targets: [
        .target(name: "NativeBridge", dependencies: [.product(name: "ReSignMobileDevice", package: "MobileDevice")],
                cSettings: [.unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"])],
                linkerSettings: [
                    .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
                    .linkedLibrary("plist-2.0"),
                    .linkedFramework("Foundation")
                ]),
        .executableTarget(name: "ReSign", dependencies: [
            "NativeBridge", .product(name: "SideSign", package: "SideSign"),
            .product(name: "AnisetteKit", package: "AnisetteKit")
        ], linkerSettings: [.linkedFramework("Security")]),
        .testTarget(name: "ReSignTests", dependencies: ["ReSign", .product(name: "SideSign", package: "SideSign")])
    ],
    swiftLanguageModes: [.v5]
)
