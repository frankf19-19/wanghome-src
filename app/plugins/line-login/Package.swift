// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WangmiaoLineLogin",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WangmiaoLineLogin", targets: ["LineLoginPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/line/line-sdk-ios-swift.git", exact: "5.17.0")
    ],
    targets: [
        .target(
            name: "LineLoginPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "LineSDK", package: "line-sdk-ios-swift")
            ],
            path: "ios/Sources/LineLoginPlugin")
    ]
)
