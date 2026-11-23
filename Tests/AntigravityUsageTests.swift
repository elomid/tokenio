import Foundation

@main
struct AntigravityUsageTests {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let log = temp.appendingPathComponent("calls.log")
        // Each mock answers --version, logs every invocation, then runs `body` for /usage.
        func mock(_ name: String, version: String = "1.5.14", _ body: String) throws -> URL {
            let url = temp.appendingPathComponent(name)
            try """
            #!/usr/bin/python3
            import sys, json, time
            open(\(String(reflecting: log.path)), "a").write(" ".join(sys.argv[1:]) + "\\n")
            if sys.argv[1:] == ["--version"]:
                print(\(String(reflecting: version))); sys.exit(0)
            \(body)
            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let payload: [String: Any] = [
            "status": "SUCCESS", "num_turns": 0,
            "command": ["name": "usage", "data": ["groups": [
                ["name": "Gemini Models", "buckets": [
                    ["window": "weekly", "remaining_fraction": 0.97, "reset_time": "2030-01-08T00:00:00Z"],
                    ["window": "5h", "remaining_fraction": 0.25, "reset_time": "2030-01-01T05:00:00.5Z"],
                ]],
                // Third-party groups are hidden even when they're the closest to running out.
                ["name": "Claude and GPT models", "buckets": [
                    ["window": "5h", "remaining_fraction": 0.0, "reset_time": "2030-01-01T05:00:00Z"],
                ]],
                ["name": "Partner models", "buckets": [
                    ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.0, "reset_time": "2030-01-08T00:00:00Z"],
                ]],
                ["name": "Imagen", "buckets": [
                    ["window": "weekly", "remaining_fraction": 1.2, "reset_time": "2030-01-08T00:00:00Z"],
                    ["window": "5h", "remaining_fraction": "bad", "reset_time": "2030-01-01T05:00:00Z"],
                ]],
                ["name": "Gemini 3 Flash", "buckets": [
                    ["name": "Gemini 3 Flash Weekly Limit", "window": "fortnight", "remaining_fraction": 0.5, "reset_time": "2030-01-08T00:00:00Z"],
                ]],
            ]]],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let success = try mock("success", "print('warming up', flush=True)\nprint(\(String(reflecting: json)), flush=True)\n")
        let usage = try AntigravityUsage.fetch(executable: success, timeout: 5)
        precondition(usage.limits.map(\.title) == ["5-hour - Gemini", "Weekly - Gemini", "Weekly - Imagen",
                                                    "Gemini 3 Flash Weekly Limit - Gemini 3 Flash"], "\(usage.limits.map(\.title))")
        precondition(abs(usage.limits[0].usedPercent - 75) < 0.001 && usage.limits[0].windowSecs == 5 * 3600)
        precondition(abs(usage.limits[1].usedPercent - 3) < 0.001 && usage.limits[1].windowSecs == 7 * 86400)
        precondition(usage.limits[2].usedPercent == 0, "Remaining fraction above 1 clamps to 0% used")
        precondition(usage.limits[3].windowSecs == nil)
        precondition(usage.tightest?.title == "5-hour - Gemini")
        let calls = try String(contentsOf: log, encoding: .utf8)
        precondition(calls == "--version\n-p /usage --output-format json\n", calls)

        // Old CLIs would send "/usage" to the model, so they must never get that call.
        try? FileManager.default.removeItem(at: log)
        let old = try mock("old", version: "agy 1.1.10", "print(\(String(reflecting: json)))\n")
        do { _ = try AntigravityUsage.fetch(executable: old, timeout: 5); preconditionFailure("Expected old version error") }
        catch { precondition(error.localizedDescription.contains("agy update")) }
        let oldCalls = try String(contentsOf: log, encoding: .utf8)
        precondition(oldCalls == "--version\n", oldCalls)
        precondition(AntigravityUsage.parseVersion(Data("1.1.11\n".utf8)) == [1, 1, 11])

        let signedOut = try mock("signedout", "print(json.dumps({'status': 'ERROR', 'response': 'Not signed in'}))\n")
        do { _ = try AntigravityUsage.fetch(executable: signedOut, timeout: 5); preconditionFailure("Expected login error") }
        catch { precondition(error.localizedDescription.contains("Not signed in")) }

        let crashed = try mock("crashed", "print('auth token expired', file=sys.stderr); sys.exit(2)\n")
        do { _ = try AntigravityUsage.fetch(executable: crashed, timeout: 5); preconditionFailure("Expected exit error") }
        catch { precondition(error.localizedDescription.contains("auth token expired")) }

        let empty = try mock("empty", "print(json.dumps({'status': 'SUCCESS', 'command': {'data': {'groups': []}}}))\n")
        do { _ = try AntigravityUsage.fetch(executable: empty, timeout: 5); preconditionFailure("Expected no-limits error") }
        catch { precondition(error.localizedDescription.contains("No Antigravity usage")) }

        let stalled = try mock("stalled", "time.sleep(10)\n")
        let started = Date()
        do { _ = try AntigravityUsage.fetch(executable: stalled, timeout: 0.5); preconditionFailure("Expected timeout") }
        catch { precondition(error.localizedDescription.contains("too long")) }
        precondition(Date().timeIntervalSince(started) < 2)

        let bin = temp.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: success, to: bin.appendingPathComponent("agy"))
        precondition(AntigravityUsage.executableURL(home: temp.path, environment: ["PATH": "/usr/bin:/bin"])?.lastPathComponent == "agy")
        print("PASS: JSON parsing and ordering; Claude/GPT groups hidden; clamping; fractional dates; version gate never sends /usage to old CLIs; sign-in, exit and empty errors; bounded timeout; executable lookup")
    }
}
