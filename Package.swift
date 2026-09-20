// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacSVN",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacSVN",
            path: "Sources/MacSVN"
        )
    ]
)
