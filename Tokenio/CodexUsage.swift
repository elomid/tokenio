import Foundation
import Darwin

struct CodexUsage: Codable {
    let usedPercent: Double
    let resetsAt: TimeInterval
    let windowDurationMins: Double
    var fetchedAt: TimeInterval = Date().timeIntervalSince1970

    static var cached: CodexUsage? {
        guard let data = UserDefaults.standard.data(forKey: "codexUsage") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    // Finder apps inherit a minimal PATH. npm's launcher needs Node, but its
    // platform package contains a native executable we can run directly.
    static func executableURL(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex",
                     home + "/Applications/Codex.app/Contents/Resources/codex"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if resolved.pathExtension == "js" {
                let root = resolved.deletingLastPathComponent().deletingLastPathComponent()
                #if arch(arm64)
                let platform = "arm64", triple = "aarch64-apple-darwin"
                #else
                let platform = "x64", triple = "x86_64-apple-darwin"
                #endif
                let vendors = [root.appendingPathComponent("node_modules/@openai/codex-darwin-\(platform)/vendor"),
                               root.deletingLastPathComponent().appendingPathComponent("codex-darwin-\(platform)/vendor"),
                               root.appendingPathComponent("vendor")]
                for vendor in vendors {
                    // Support both current and earlier npm package layouts.
                    for directory in ["bin", "codex"] {
                        let native = vendor.appendingPathComponent("\(triple)/\(directory)/codex")
                        if FileManager.default.isExecutableFile(atPath: native.path) { return native }
                    }
                }
            }
            return resolved
        }
        return nil
    }

    static func fetch(executable: URL? = nil, timeout: TimeInterval = 20) throws -> CodexUsage {
        guard let executable = executable ?? executableURL() else {
            throw failure("Install the Codex CLI, then run codex login in Terminal. You can turn off Codex in Providers if you only use Claude.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ([executable.deletingLastPathComponent().path, home + "/.local/bin",
                                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                               + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw failure("Could not start Codex. Check your Codex CLI installation and retry.") }
        // A child exiting during the handshake must produce an error, not SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Bound reads themselves: a launcher or inherited pipe must never leave
        // the refresh worker blocked after the deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "tokenio", "version": "1.0"]]])
        var buffer = Data()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure("Codex took too long to respond. Check your connection and retry.") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure("Could not read the Codex response. Retry the connection.")
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw failure("Codex exited before returning usage. Check that codex runs in Terminal and sign in with codex login.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw failure("Codex returned an oversized response. Update the Codex CLI and retry.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if let error = message["error"] as? [String: Any] {
                    let detail = error["message"] as? String ?? "Unknown Codex error."
                    throw failure("\(detail)\n\nCheck your Codex login in Terminal with codex login. API-key-only accounts do not provide a ChatGPT weekly quota.")
                }
                if id == 0 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 {
                    guard let result = message["result"] as? [String: Any] else {
                        throw failure("Invalid Codex usage response")
                    }
                    let usage = try parse(result)
                    return usage
                }
            }
        }
    }

    static func parse(_ result: [String: Any]) throws -> CodexUsage {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        for key in ["primary", "secondary"] {
            guard let window = bucket?[key] as? [String: Any],
                  let minutes = (window["windowDurationMins"] as? NSNumber)?.doubleValue, minutes == 10080,
                  let percent = (window["usedPercent"] as? NSNumber)?.doubleValue, percent.isFinite,
                  let reset = (window["resetsAt"] as? NSNumber)?.doubleValue, reset > 0 else { continue }
            return CodexUsage(usedPercent: max(0, min(100, percent)), resetsAt: reset, windowDurationMins: minutes)
        }
        throw failure("No Codex weekly quota — check codex login")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Tokenio.Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
