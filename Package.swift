// swift-tools-version:5.2

import PackageDescription

let package = Package(
  name: "HTTPDownloader",
  platforms: [
    .macOS(.v10_15)
  ],
  products: [
    .library(
      name: "HTTPDownloader",
      targets: ["HTTPDownloader"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.1.0"),
    .package(url: "https://github.com/kojirou1994/Kwift.git",  .upToNextMinor(from: "0.6.0"))
  ],
  targets: [
    .target(
      name: "HTTPDownloader",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "KwiftUtility", package: "Kwift")
    ]),
    .testTarget(
      name: "HTTPDownloaderTests",
      dependencies: ["HTTPDownloader"]),
  ]
)
