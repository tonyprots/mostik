// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mostik",
    platforms: [.macOS(.v14)],
    targets: [
        // Чистая логика, покрыта MostikCoreTests.
        .target(name: "MostikCore"),
        // Платформенный слой: звук, хоткеи, вставка, движок.
        .target(name: "MostikKit", dependencies: ["MostikCore"]),
        // Экраны SwiftUI и AppModel — без звука и движка.
        .target(name: "MostikUI", dependencies: ["MostikCore"]),
        .executableTarget(name: "Mostik", dependencies: ["MostikCore", "MostikKit", "MostikUI"]),
        // Fixtures/ — замороженные файлы данных прошлых версий; тест читает их по #filePath.
        .executableTarget(name: "MostikCoreTests", dependencies: ["MostikCore"], exclude: ["Fixtures"]),
        // Рендер экранов с демо-данными в PNG: приёмка дизайна без разрешений.
        .executableTarget(name: "MostikSnapshots", dependencies: ["MostikCore", "MostikUI"]),
        // Синтетические замеры без микрофона и разрешений (docs/bench.md).
        .executableTarget(name: "MostikBench", dependencies: ["MostikCore", "MostikKit", "MostikUI"]),
    ]
)
