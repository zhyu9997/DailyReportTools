// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DailyReport",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DailyReport",
            path: "Sources/DailyReport"
        )
    ]
)
