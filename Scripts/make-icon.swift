import Foundation

func findRoot() -> URL {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(launchPath) failed (\(process.terminationStatus))")
    }
}

let root = findRoot()
let resources = root.appendingPathComponent("Resources")
let assets = root.appendingPathComponent("Sources/GoAway/Assets")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let masterCandidates = [
    assets.appendingPathComponent("AppLogo.png"),
    resources.appendingPathComponent("AppIcon.png")
]
guard let master = masterCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
    fatalError("Missing AppLogo.png / AppIcon.png")
}

let logo = assets.appendingPathComponent("AppLogo.png")
let png = resources.appendingPathComponent("AppIcon.png")
if master.standardizedFileURL != logo.standardizedFileURL {
    try? FileManager.default.removeItem(at: logo)
    try FileManager.default.copyItem(at: master, to: logo)
}
if master.standardizedFileURL != png.standardizedFileURL {
    try? FileManager.default.removeItem(at: png)
    try FileManager.default.copyItem(at: master, to: png)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GoAway.iconset")
let icns = FileManager.default.temporaryDirectory.appendingPathComponent("GoAway.icns")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: icns)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let slices: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, name) in slices {
    try run("/usr/bin/sips", [
        "-z", "\(size)", "\(size)", master.path,
        "--out", iconset.appendingPathComponent(name).path
    ])
}

try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
try? FileManager.default.removeItem(at: resources.appendingPathComponent("AppIcon.icns"))
try FileManager.default.copyItem(at: icns, to: resources.appendingPathComponent("AppIcon.icns"))
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: icns)
print("Wrote AppIcon and AppLogo")
