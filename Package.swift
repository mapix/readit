// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Readit",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Readit", path: "Sources/Readit")]
)
