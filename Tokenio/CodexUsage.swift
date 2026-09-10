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

    static func fetch() throws -> CodexUsage {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw failure("Install Codex CLI and run codex login")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
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
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw failure("Codex unavailable or timed out — retry") }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw failure("Codex unavailable — check codex login") }
                if id == 0 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 {
                    guard let result = message["result"] as? [String: Any] else {
                        throw failure("Invalid Codex usage response")
                    }
                    let usage = try parse(result)
                    UserDefaults.standard.set(try JSONEncoder().encode(usage), forKey: "codexUsage")
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
