// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMovieCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "iMovieCore", targets: ["iMovieCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.9.6")],
    targets: [
        .target(name: "iMovieCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")], path: "Sources/Core"),
        .testTarget(name: "iMovieCoreTests", dependencies: ["iMovieCore"], path: "Tests/CoreTests")
    ]
)
