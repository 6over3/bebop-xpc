// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "bebop-xpc",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "BebopXPC", targets: ["BebopXPC"]),
    .executable(name: "ExifServiceExample", targets: ["ExifServiceExample"]),
  ],
  dependencies: [
    .package(path: "../bebop-vnext"),
    .package(url: "https://github.com/6over3/libexif", branch: "main"),
  ],
  targets: [
    .target(
      name: "BebopXPC",
      dependencies: [
        .product(name: "SwiftBebop", package: "bebop-vnext")
      ],
      path: "Sources/BebopXPC"
    ),
    .testTarget(
      name: "BebopXPCTests",
      dependencies: ["BebopXPC"],
      path: "Tests/BebopXPCTests"
    ),
    .executableTarget(
      name: "ExifServiceExample",
      dependencies: [
        "BebopXPC",
        .product(name: "Exif", package: "libexif"),
      ],
      path: "Examples/ExifService/Sources"
    ),
  ]
)
