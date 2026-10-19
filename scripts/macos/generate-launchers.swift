import AppKit
import CryptoKit
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let prefix = "local.claudeprofiles."
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct App: Decodable {
    let profile: String
    let name: String
    let color: String
    var bundleID: String { prefix + profile }
    var filename: String { name + ".app" }
}
struct Config: Decodable {
    let apps: [App]
    let isPlaceholder: Bool
    private enum CodingKeys: String, CodingKey { case apps }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A fresh install starts with {"apps": {}}; populated configs use an array.
        if let object = try? values.decode([String: String].self, forKey: .apps), object.isEmpty {
            apps = []
            isPlaceholder = true
        } else {
            apps = try values.decode([App].self, forKey: .apps)
            isPlaceholder = false
        }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
}

func color(_ value: String) throws -> NSColor {
    guard value.count == 7, value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
          let rgb = UInt32(value.dropFirst(), radix: 16) else {
        throw Failure("Invalid color '\(value)'. Use a hex code in #RRGGBB format.")
    }
    let result = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                         green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    return result
}

func validate(_ config: Config) throws {
    var names = Set<String>(), profiles = Set<String>()
    for app in config.apps {
        guard app.profile.count <= 64, app.profile.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw Failure("Profiles must use 1–64 lowercase letters, numbers, or hyphens: \(app.profile)")
        }
        guard !app.name.isEmpty, app.name == app.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !app.name.hasPrefix("."), !app.name.lowercased().hasSuffix(".app"),
              app.filename.utf8.count <= 240,
              app.name.rangeOfCharacter(from: .controlCharacters) == nil,
              !app.name.contains("/"), !app.name.contains(":") else {
            throw Failure("Invalid app name: \(app.name)")
        }
        guard names.insert(app.name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
              profiles.insert(app.profile).inserted else {
            throw Failure("Each app needs a unique name and profile (including default).")
        }
        _ = try color(app.color)
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(task.terminationStatus)).") }
    return task.terminationStatus
}

func plist(_ app: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}
func exists(_ url: URL) -> Bool {
    fm.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
func samePath(_ left: URL, _ right: URL) -> Bool {
    // FileManager can return /private/var paths for a /var destination on macOS.
    left.resolvingSymlinksInPath().standardizedFileURL.path == right.resolvingSymlinksInPath().standardizedFileURL.path
}

// Render the system's current Claude artwork; preserve white details and alpha.
func icon(_ base: NSImage, tint: NSColor, directory: URL) throws -> URL {
    let iconset = directory.appendingPathComponent("Claude.iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw Failure("Cannot allocate icon bitmap.") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            base.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            var visible = false
            for y in 0..<pixels {
                for x in 0..<pixels {
                    guard let source = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), source.alphaComponent > 0 else { continue }
                    if source.alphaComponent > 0.5 { visible = true }
                    if source.saturationComponent > 0.12 {
                        bitmap.setColor(NSColor(calibratedHue: tint.hueComponent,
                            saturation: min(1, source.saturationComponent * tint.saturationComponent / 0.85),
                            brightness: min(1, source.brightnessComponent * tint.brightnessComponent / 0.95),
                            alpha: source.alphaComponent), atX: x, y: y)
                    }
                }
            }
            guard visible else { throw Failure("macOS could not render Claude's icon. Run from a logged-in desktop session.") }
            let png = bitmap.representation(using: .png, properties: [:])!
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let output = directory.appendingPathComponent("Claude.icns")
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
    return output
}

func buildApp(_ app: App, base: NSImage, staging: URL, work: URL) throws {
    let bundle = staging.appendingPathComponent(app.filename)
    let contents = bundle.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    let executable = contents.appendingPathComponent("MacOS/claude-launcher")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: root.appendingPathComponent("scripts/macos/launch-claude.sh"), to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let iconFile = try icon(base, tint: color(app.color), directory: work.appendingPathComponent(app.profile))
    let digest = SHA256.hash(data: try Data(contentsOf: iconFile)).prefix(8).map { String(format: "%02x", $0) }.joined()
    // A new filename invalidates cached icons when changing color.
    let iconName = "Claude-\(digest).icns"
    try fm.copyItem(at: iconFile, to: resources.appendingPathComponent(iconName))
    let info: [String: Any] = [
        "CFBundleName": app.name, "CFBundleDisplayName": app.name,
        "CFBundleIdentifier": app.bundleID, "CFBundleExecutable": "claude-launcher",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "CFBundleIconFile": iconName, "LSUIElement": true, "NSHighResolutionCapable": true,
        "ClaudeProfile": app.profile
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
}

// Replace only this tool's bundles. Stage replacements first; restore originals on failure.
func deploy(_ apps: [App], from staging: URL, to destination: URL, prune: Bool) throws {
    guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
        throw Failure("Destination must not be a symlink: \(destination.path)")
    }
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let wanted = Set(apps.map(\.profile))
    var previous: [URL] = []
    var seen = Set<String>()
    for item in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) where item.pathExtension == "app" {
        // Match by profile to also migrate launchers built with manually chosen IDs.
        guard let info = plist(item), let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(prefix),
              let profile = info["ClaudeProfile"] as? String, prune || wanted.contains(profile) else { continue }
        guard (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw Failure("Refusing to replace symlink: \(item.path)")
        }
        guard seen.insert(profile).inserted else { throw Failure("Duplicate installed launcher profile: \(profile)") }
        previous.append(item)
    }
    for app in apps {
        let target = destination.appendingPathComponent(app.filename)
        if exists(target) && !previous.contains(where: { samePath($0, target) }) {
            throw Failure("Another app already uses this name: \(target.path)")
        }
    }
    let transaction = destination.appendingPathComponent(".claude-profiles-\(UUID().uuidString)")
    let backup = transaction.appendingPathComponent("old")
    let prepared = transaction.appendingPathComponent("new")
    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    try fm.createDirectory(at: prepared, withIntermediateDirectories: true)
    var moved: [URL] = [], installed: [URL] = []
    do {
        for app in apps { try fm.copyItem(at: staging.appendingPathComponent(app.filename), to: prepared.appendingPathComponent(app.filename)) }
        for old in previous {
            try fm.moveItem(at: old, to: backup.appendingPathComponent(old.lastPathComponent))
            moved.append(old)
        }
        for app in apps {
            let target = destination.appendingPathComponent(app.filename)
            try fm.moveItem(at: prepared.appendingPathComponent(app.filename), to: target)
            installed.append(target)
        }
    } catch {
        let originalError = error
        do {
            for target in installed { try fm.removeItem(at: target) }
            for old in moved { try fm.moveItem(at: backup.appendingPathComponent(old.lastPathComponent), to: old) }
            try fm.removeItem(at: transaction)
        } catch { throw Failure("Update failed. Previous launchers are backed up at \(backup.path). \(error.localizedDescription)") }
        throw originalError
    }
    try fm.removeItem(at: transaction)
    if !prune {
        let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for old in previous where !installed.contains(where: { samePath($0, old) }) { _ = try? run(register, ["-u", old.path]) }
        for app in installed {
            do { try run(register, ["-f", app.path]) }
            catch { print("Installed; restart Raycast if its app list is stale.") }
        }
    }
}

func main() throws {
    var configURL = root.appendingPathComponent("config.json")
    var output = root.appendingPathComponent("apps")
    var destination = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    var install = false, validateOnly = false
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        switch option {
        case "--install": install = true
        case "--validate": validateOnly = true
        case "--config", "--output", "--install-dir":
            guard !arguments.isEmpty else { throw Failure("Missing value for \(option)") }
            let url = URL(fileURLWithPath: NSString(string: arguments.removeFirst()).expandingTildeInPath).standardizedFileURL
            if option == "--config" { configURL = url }
            if option == "--output" { output = url }
            if option == "--install-dir" { destination = url; install = true }
        case "--help", "-h":
            print("Usage: ./scripts/macos/generate-launchers.sh [--install] [--validate] [--config FILE] [--output DIR] [--install-dir DIR]")
            return
        default: throw Failure("Unknown argument: \(option)")
        }
    }
    guard exists(configURL) else {
        guard install && !validateOnly else { throw Failure("Missing config. Run Claude Profiles - macOS.command (Create launchers) or copy config.example.json to config.json.") }
        try Data("{\n  \"apps\": {}\n}\n".utf8).write(to: configURL, options: .withoutOverwriting)
        warn("Config was missing. Created \(configURL.path) with an empty apps object. Add your apps using config.example.json, then run the installer again.")
        return
    }
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    try validate(config)
    if validateOnly { print("Valid configuration: \(config.apps.count) apps."); return }
    if config.isPlaceholder {
        warn("No apps configured. Replace apps: {} with the array from config.example.json, then run the installer again.")
        return
    }
    guard let claude = [URL(fileURLWithPath: "/Applications/Claude.app"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app")]
        .first(where: { fm.fileExists(atPath: $0.path) }) else { throw Failure("Install Claude Desktop in Applications first.") }
    guard !install || output.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
        throw Failure("Build output and installation directory must be different.")
    }
    let work = root.appendingPathComponent(".build/\(UUID().uuidString)")
    let staging = work.appendingPathComponent("apps")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let base = NSWorkspace.shared.icon(forFile: claude.path)
    for app in config.apps {
        try buildApp(app, base: base, staging: staging, work: work)
        print("Built: \(app.name)")
    }
    try deploy(config.apps, from: staging, to: output, prune: true)
    if install { try deploy(config.apps, from: staging, to: destination, prune: false) }
    print("\(config.apps.count) apps in \(output.path)" + (install ? "\nInstalled in \(destination.path)" : ""))
}

do { try main() }
catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
