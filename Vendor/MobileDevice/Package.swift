// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileDevice",
    platforms: [.macOS("27.0")],
    products: [.library(name: "ReSignMobileDevice", type: .dynamic, targets: ["ReSignMobileDevice"])],
    targets: [
        .systemLibrary(name: "CPlist", path: "System/CPlist", pkgConfig: "libplist-2.0", providers: [.brew(["libplist", "pkgconf"])]),
        .systemLibrary(name: "CUsbmuxd", path: "System/CUsbmuxd", pkgConfig: "libusbmuxd-2.0", providers: [.brew(["libusbmuxd"])]),
        .systemLibrary(name: "CDeviceGlue", path: "System/CDeviceGlue", pkgConfig: "libimobiledevice-glue-1.0", providers: [.brew(["libimobiledevice-glue"])]),
        .systemLibrary(name: "COpenSSL", path: "System/COpenSSL", pkgConfig: "openssl", providers: [.brew(["openssl@4"])]),
        .target(name: "ReSignMobileDevice", dependencies: ["CPlist", "CUsbmuxd", "CDeviceGlue", "COpenSSL"],
                path: ".", exclude: ["Package.swift", "UPSTREAM.md", "COPYING", "COPYING.LESSER", "System"],
                sources: ["src", "common"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .headerSearchPath("internal"), .define("HAVE_CONFIG_H")],
                linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("SystemConfiguration")])
    ]
)
