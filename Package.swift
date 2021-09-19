// swift-tools-version:5.2

import PackageDescription

let package = Package(
  name: "HTTPDownloader",
  products: [
    .library(name: "HTTPDownloader", targets: ["HTTPDownloader"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.1.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "HTTPDownloader",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "DequeModule", package: "swift-collections"),
    ]),
    .testTarget(
      name: "HTTPDownloaderTests",
      dependencies: ["HTTPDownloader"]),
  ]
)
