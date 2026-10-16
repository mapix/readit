// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Readlet",
  platforms: [.macOS(.v14), .iOS(.v17)],
  targets: [
    .executableTarget(name: "Readlet", path: "Sources/Readlet"),
    .testTarget(name: "ReadletTests", dependencies: ["Readlet"], path: "Tests/ReadletTests"),
  ]
)
