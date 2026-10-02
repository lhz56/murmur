// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MurmurLocalSpeech", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.6")],
    targets: [.executableTarget(name: "MurmurParakeet", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)
