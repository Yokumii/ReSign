// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReSign",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ReSign", targets: ["ReSign"])],
    dependencies: [
        .package(path: "Vendor/SideSign"),
        .package(url: "https://github.com/mahee96/AnisetteKit.git", revision: "db8b41022697b6c19be8a5f01a1ce834145a2a26")
    ],
    targets: [
        .systemLibrary(name: "CMobileDevice", pkgConfig: "libimobiledevice-1.0",
                       providers: [.brew(["libimobiledevice", "libplist", "pkgconf"])]),
        .target(name: "NativeBridge", dependencies: ["CMobileDevice"],
                cSettings: [.unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"])],
                linkerSettings: [
                    .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
                    .linkedLibrary("imobiledevice-1.0"), .linkedLibrary("plist-2.0"),
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
