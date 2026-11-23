import Foundation
import Darwin

struct AntigravityUsage: Codable {
    struct Limit: Codable, Equatable {
        let title: String
        let usedPercent: Double
        let resetsAt: TimeInterval
        let windowSecs: TimeInterval?
    }

    let limits: [Limit]
    var fetchedAt: TimeInterval = Date().timeIntervalSince1970

    /// The limit closest to running out, shown in the menu bar icon.
    var tightest: Limit? {
        limits.reduce(nil) { best, limit in
            guard let best else { return limit }
            return limit.usedPercent > best.usedPercent ? limit : best
        }
    }

    static var cached: AntigravityUsage? {
        guard let data = UserDefaults.standard.data(forKey: "antigravityUsage") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Print-mode slash commands answer locally from this version on. Older
    /// builds would send "/usage" to the model as a prompt and spend quota.
    static let minimumVersion = [1, 1, 11]

    static func executableURL(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = [home + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/agy" }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return nil
    }

    static func fetch(executable: URL? = nil, timeout: TimeInterval = 20) throws -> AntigravityUsage {
        guard let executable = executable ?? executableURL() else {
            throw failure("Install the Antigravity CLI (agy), then sign in by running agy in Terminal. You can turn off Antigravity in Providers if you don't use it.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let versionOutput = try run(executable, ["--version"], deadline: deadline)
        guard let version = parseVersion(versionOutput) else {
            throw failure("Could not read the Antigravity CLI version. Check that agy runs in Terminal.")
        }
        guard version.lexicographicallyPrecedes(minimumVersion) == false else {
            throw failure("Antigravity CLI \(version.map(String.init).joined(separator: ".")) is too old to report usage. Run agy update in Terminal, then retry.")
        }
        let output = try run(executable, ["-p", "/usage", "--output-format", "json"], deadline: deadline)
        return try parse(output)
    }

    static func parseVersion(_ data: Data) -> [Int]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }

    static func parse(_ data: Data) throws -> AntigravityUsage {
        // Diagnostics may precede the JSON payload; start at the first brace.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let json = (try? JSONSerialization.jsonObject(with: data[start...])) as? [String: Any] else {
            let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure((text.isEmpty ? "Antigravity returned no usage." : text) + "\n\nCheck that you're signed in by running agy in Terminal.")
        }
        guard json["status"] as? String == "SUCCESS" else {
            let detail = (json["response"] as? String ?? json["error"] as? String ?? "Unknown Antigravity error.")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure("\(detail)\n\nCheck that you're signed in by running agy in Terminal.")
        }
        let groups = ((json["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        var limits: [Limit] = []
        for group in groups where !isThirdPartyGroup(group) {
            let name = shortGroupName(group["name"] as? String ?? "")
            var groupLimits: [Limit] = []
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue, remaining.isFinite,
                      let resetString = bucket["reset_time"] as? String, let reset = parseDate(resetString) else { continue }
                let window = bucket["window"] as? String ?? ""
                let label = windowLabel(window) ?? (bucket["name"] as? String ?? "Limit")
                groupLimits.append(Limit(title: name.isEmpty ? label : "\(label) - \(name)",
                                         usedPercent: max(0, min(100, (1 - remaining) * 100)),
                                         resetsAt: reset, windowSecs: windowSeconds(window)))
            }
            // Match Claude's order: shorter windows first.
            limits += groupLimits.enumerated().sorted {
                ($0.element.windowSecs ?? .infinity, $0.offset) < ($1.element.windowSecs ?? .infinity, $1.offset)
            }.map(\.element)
        }
        guard !limits.isEmpty else { throw failure("No Antigravity usage limits found. Check that you're signed in by running agy in Terminal.") }
        return AntigravityUsage(limits: limits)
    }

    static func windowSeconds(_ window: String) -> TimeInterval? {
        let window = window.lowercased()
        switch window {
        case "weekly": return 7 * 86400
        case "daily": return 86400
        case "monthly": return 30 * 86400
        default:
            guard let unit = window.last, let count = Double(window.dropLast()), count > 0 else { return nil }
            switch unit {
            case "m": return count * 60
            case "h": return count * 3600
            case "d": return count * 86400
            case "w": return count * 7 * 86400
            default: return nil
            }
        }
    }

    private static func windowLabel(_ window: String) -> String? {
        switch window.lowercased() {
        case "weekly": return "Weekly"
        case "daily": return "Daily"
        case "monthly": return "Monthly"
        case let w where w.hasSuffix("h") && Int(w.dropLast()) != nil: return "\(w.dropLast())-hour"
        default: return nil
        }
    }

    /// Antigravity's quota for Claude and GPT models. Tokenio tracks Claude
    /// directly, so only Google's own model limits are shown.
    static func isThirdPartyGroup(_ group: [String: Any]) -> Bool {
        let buckets = group["buckets"] as? [[String: Any]] ?? []
        if buckets.contains(where: { ($0["id"] as? String)?.hasPrefix("3p-") == true }) { return true }
        let name = (group["name"] as? String ?? "").lowercased()
        return name.contains("claude") || name.contains("gpt")
    }

    private static func shortGroupName(_ name: String) -> String {
        for suffix in [" Models", " models"] where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        return name
    }

    private static func parseDate(_ string: String) -> TimeInterval? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)?.timeIntervalSince1970
    }

    /// Runs agy with stdout and stderr combined. Reads are bounded by the
    /// deadline so a stalled CLI never blocks the refresh worker.
    private static func run(_ executable: URL, _ arguments: [String], deadline: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ([executable.deletingLastPathComponent().path, home + "/.local/bin",
                                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                               + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw failure("Could not start the Antigravity CLI. Check your agy installation and retry.") }
        try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure("Antigravity took too long to respond. Check your connection and retry.") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure("Could not read the Antigravity response. Retry the connection.")
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor.fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw failure("Antigravity returned an oversized response. Update the CLI with agy update and retry.") }
        }
        // Output closed; give the process a moment to report its exit status.
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if !process.isRunning, process.terminationStatus != 0 {
            let text = String(decoding: buffer.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure((text.isEmpty ? "The Antigravity CLI exited with an error." : text) + "\n\nCheck that agy runs in Terminal and that you're signed in.")
        }
        return buffer
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Tokenio.Antigravity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
