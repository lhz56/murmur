// swift-tools-version: 6.0
import PackageDescription
// Murmur's natural voice for Ask. Kept apart from LocalSpeech so dictation's
// Parakeet helper stays on the FluidAudio version it was tested with.
let package = Package(
    name: "MurmurLocalVoice", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")],
    targets: [.executableTarget(name: "MurmurVoice", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)
