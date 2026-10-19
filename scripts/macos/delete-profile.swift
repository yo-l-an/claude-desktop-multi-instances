import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let home = fm.homeDirectoryForCurrentUser
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func validProfile(_ value: String) -> Bool {
    value.count <= 64 && value.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
}
func exists(_ url: URL) -> Bool {
    fm.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
func children(_ directory: URL) throws -> [URL] {
    guard exists(directory) else { return [] }
    return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
}
func refuseSymlink(_ url: URL) throws {
    // Check every ancestor: never act on data reached through a redirected folder.
    var current = url
    while current.path != "/" {
        if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw Failure("Refusing a symlink path: \(current.path)")
        }
        current.deleteLastPathComponent()
    }
}
func requireProfileClosed(_ profile: String, dataDirectory: URL) throws {
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "args="]
    task.standardOutput = output
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw Failure("Cannot check running apps. No files were removed.") }
    let commands = String(decoding: data, as: UTF8.self).split(separator: "\n")
    let running = commands.contains(where: {
        let command = $0.trimmingCharacters(in: .whitespaces)
        let appPaths = ["/Applications/Claude.app", home.appendingPathComponent("Applications/Claude.app").path]
        guard let appPath = appPaths.first(where: { command.hasPrefix($0 + "/Contents/") }) else { return false }
        let executable = appPath + "/Contents/MacOS/Claude"
        let isMain = command == executable || command.hasPrefix(executable + " ")
        // Launchers use one stable data directory per profile. Helpers may carry it too.
        for flag in ["--user-data-dir=", "--user-data-dir "] {
            let needle = flag + dataDirectory.path
            if let range = command.range(of: needle) {
                let tail = command[range.upperBound...]
                if tail.isEmpty || tail.first?.isWhitespace == true { return true }
            }
        }
        return profile == "default" && isMain && !command.contains("--user-data-dir")
    })
    guard !running else {
        throw Failure("Profile '\(profile)' is running. Quit that Claude instance (Cmd+Q), then try again. Other profiles can stay open.")
    }
}
func configData(_ config: [String: Any], entries: [[String: Any]]) throws -> Data {
    func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    let rows = try entries.map { entry -> String in
        let keys = ["profile", "name", "color"].filter { entry[$0] != nil }
            + entry.keys.filter { !["profile", "name", "color"].contains($0) }.sorted()
        return "    { " + (try keys.map { try json($0) + ": " + json(entry[$0]!) }).joined(separator: ", ") + " }"
    }
    var fields = ["  \"apps\": [" + (rows.isEmpty ? "" : "\n" + rows.joined(separator: ",\n") + "\n  ") + "]"]
    for key in config.keys.filter({ $0 != "apps" }).sorted() {
        fields.append(try "  " + json(key) + ": " + json(config[key]!))
    }
    return Data(("{\n" + fields.joined(separator: ",\n") + "\n}\n").utf8)
}
func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") {
        print("Usage: \"./Claude Profiles - macOS.command\" delete [PROFILE] [--dry-run]\nWithout PROFILE, choose interactively. Deletion always requires typed confirmation.")
        return
    }
    let dryRun = args.contains("--dry-run")
    let positional = args.filter { $0 != "--dry-run" }
    guard positional.count <= 1, !positional.contains(where: { $0.hasPrefix("-") }) else { throw Failure("Use --help for usage.") }
    let configURL = root.appendingPathComponent("config.json")
    try refuseSymlink(configURL)
    let originalConfig = exists(configURL) ? try Data(contentsOf: configURL) : nil
    var config: [String: Any] = [:]
    var entries: [[String: Any]] = []
    if let data = originalConfig {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Invalid config.json.") }
        config = object
        if let array = object["apps"] as? [[String: Any]] { entries = array }
        else if let empty = object["apps"] as? [String: Any], empty.isEmpty { entries = [] }
        else { throw Failure("config.json apps must be an array or an empty object.") }
        guard entries.allSatisfy({ ($0["profile"] as? String).map(validProfile) == true }) else {
            throw Failure("config.json contains an invalid profile.")
        }
    }
    let instances = home.appendingPathComponent(".claude-instances")
    let defaultData = home.appendingPathComponent("Library/Application Support/Claude")
    try refuseSymlink(instances)
    var profiles = Set(entries.compactMap { $0["profile"] as? String })
    for folder in try children(instances) where validProfile(folder.lastPathComponent) && folder.lastPathComponent != "default" {
        if (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { profiles.insert(folder.lastPathComponent) }
    }
    if exists(defaultData) { profiles.insert("default") }
    var launchers: [String: [URL]] = [:]
    for directory in [root.appendingPathComponent("apps"), home.appendingPathComponent("Applications")] {
        try refuseSymlink(directory)
        for app in try children(directory) where app.pathExtension == "app" {
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, id.hasPrefix("local.claudeprofiles."),
                  let profile = info["ClaudeProfile"] as? String, validProfile(profile) else { continue }
            launchers[profile, default: []].append(app)
            profiles.insert(profile)
        }
    }
    let ordered = profiles.sorted()
    guard !ordered.isEmpty else { print("No Claude profiles found."); return }
    let profile: String
    if let supplied = positional.first {
        guard profiles.contains(supplied) else { throw Failure("Unknown profile: \(supplied)") }
        profile = supplied
    } else {
        print("Choose a Claude profile to remove:\n")
        for (index, item) in ordered.enumerated() {
            let name = entries.first(where: { $0["profile"] as? String == item })?["name"] as? String
            print("\(index + 1). \(item)\(name.map { " — " + $0 } ?? "")")
        }
        print("\nNumber (Enter to cancel):", terminator: " ")
        guard let input = readLine(), !input.isEmpty else { print("Cancelled."); return }
        guard let index = Int(input), ordered.indices.contains(index - 1) else { throw Failure("Invalid selection.") }
        profile = ordered[index - 1]
    }
    let dataDirectory = profile == "default" ? defaultData : instances.appendingPathComponent(profile)
    let targets = (exists(dataDirectory) ? [dataDirectory] : []) + (launchers[profile] ?? [])
    for target in targets { try refuseSymlink(target) }
    print("\nProfile: \(profile)")
    if profile == "default" { print("WARNING: default is your regular Claude Desktop session, including its local settings and Cowork data.") }
    print("Move to Trash:")
    for target in targets { print("  \(target.path)") }
    let remaining = entries.filter { $0["profile"] as? String != profile }
    let updateConfig = remaining.count != entries.count
    if updateConfig { print("Remove its entry from: \(configURL.path)") }
    print("The original Claude app and online account will remain unchanged.")
    try requireProfileClosed(profile, dataDirectory: dataDirectory)
    if dryRun { print("Profile is not running. Dry run: no changes made."); return }
    print("\nType DELETE \(profile) to confirm:", terminator: " ")
    guard readLine() == "DELETE \(profile)" else { print("Cancelled. No changes made."); return }
    try requireProfileClosed(profile, dataDirectory: dataDirectory)
    guard (exists(configURL) ? try Data(contentsOf: configURL) : nil) == originalConfig else {
        throw Failure("config.json changed. Run this command again.")
    }
    // Serialize before touching files, and retain user config fields and app order.
    config["apps"] = remaining
    let updatedConfig = try configData(config, entries: remaining)
    for target in targets {
        try refuseSymlink(target)
        try fm.trashItem(at: target, resultingItemURL: nil)
        print("Moved to Trash: \(target.path)")
    }
    if updateConfig { try updatedConfig.write(to: configURL, options: .atomic) }
    print("Removed profile: \(profile). Restart Raycast if the old launcher is still listed.")
}
do { try main() }
catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
