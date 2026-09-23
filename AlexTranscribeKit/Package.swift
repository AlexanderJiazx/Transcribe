// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlexTranscribeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AlexTranscribeKit", targets: ["AlexTranscribeKit"]),
        .executable(name: "alex-transcribe", targets: ["AlexTranscribeCLI"]),
        .executable(name: "transcribe-test", targets: ["AlexTranscribeTestTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.4")
    ],
    targets: [
        .target(
            name: "AlexTranscribeKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "AlexTranscribeCLI",
            dependencies: ["AlexTranscribeKit"]
        ),
        .executableTarget(
            name: "AlexTranscribeTestTool",
            dependencies: ["AlexTranscribeKit"]
        ),
    ]
)
