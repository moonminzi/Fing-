// swift-tools-version:6.0
import PackageDescription

// NAGO NET의 엔진: IP 대역 계산·인터페이스/라우팅 테이블 읽기·스캔 조율·기기 종류 추정.
// UI와 Network 프레임워크를 쓰지 않아서 리눅스에서도 `swift test`로 시험된다.
let package = Package(
    name: "NagoNetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NagoNetCore", targets: ["NagoNetCore"]),
    ],
    targets: [
        .target(name: "NagoNetCore", path: "Sources/NagoNetCore"),
        .testTarget(name: "NagoNetCoreTests", dependencies: ["NagoNetCore"], path: "Tests/NagoNetCoreTests"),
    ]
)
