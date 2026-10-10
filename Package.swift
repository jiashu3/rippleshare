// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "RippleCore", targets: ["RippleCore"])]
var targets: [Target] = [
    .target(name: "RippleCore", resources: [.copy("Resources/remote.py")]),
    .testTarget(name: "RippleCoreTests", dependencies: ["RippleCore"])
]
#if os(macOS)
products.append(.executable(name: "RippleShare", targets: ["RippleShare"]))
targets.append(.executableTarget(name: "RippleShare", dependencies: ["RippleCore"]))
#endif
let package = Package(name: "RippleShare", platforms: [.macOS(.v13)],
                      products: products, targets: targets)
