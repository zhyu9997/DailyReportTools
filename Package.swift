// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DailyReport",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "DailyReport",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/DailyReport",
            swiftSettings: [
                // 显式锁定 Swift 6 语言模式：nonisolated(unsafe) / Sendable / @MainActor 的语义
                // 在 Swift 5 工具链下会退化（nonisolated(unsafe) → nonisolated），让并发保证依赖工具链默认有风险
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DailyReportTests",
            dependencies: [
                .target(name: "DailyReport"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/DailyReportTests"
        )
    ]
)
