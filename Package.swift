// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MieSQL",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MieSQL", targets: ["MieSQL"]),
        .library(name: "MieSQLCore", targets: ["MieSQLCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.2"),
    ],
    targets: [
        .target(
            name: "MieSQLCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MieSQL",
            dependencies: ["MieSQLCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MieSQLCoreTests",
            dependencies: ["MieSQLCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
