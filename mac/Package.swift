// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZawiyaTools",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZawiyaTools", targets: ["ZawiyaApp"]), .executable(name: "ZawiyaProbe", targets: ["ZawiyaProbe"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "ZawiyaCore"),
        .executableTarget(name: "ZawiyaApp", dependencies: ["ZawiyaCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "ZawiyaProbe", dependencies: ["ZawiyaCore"]),
        .testTarget(name: "ZawiyaCoreTests", dependencies: ["ZawiyaCore", "ZawiyaApp"])
    ]
)
