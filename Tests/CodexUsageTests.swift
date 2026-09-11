import Foundation

@main
struct CodexUsageTests {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func mock(_ name: String, _ body: String) throws -> URL {
            let url = temp.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys, json, time\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let success = try mock("success", """
        sys.stdin.readline()
        print('diagnostic line ignored', flush=True)
        print('{"id":0,"result":{}}', flush=True)
        sys.stdin.readline()
        sys.stdin.readline()
        response = json.dumps({"id":1,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":99,"resetsAt":1900000000},"secondary":{"windowDurationMins":10080,"usedPercent":18,"resetsAt":1900000000}}}}})
        sys.stdout.write(response[:30]); sys.stdout.flush()
        time.sleep(0.02)
        print(response[30:], flush=True)
        time.sleep(10)
        """)
        let usage = try CodexUsage.fetch(executable: success, timeout: 3)
        precondition(usage.usedPercent == 18 && usage.windowDurationMins == 10080)
        let denied = try mock("denied", "sys.stdin.readline()\nprint('{\"id\":0,\"error\":{\"message\":\"Login required\"}}', flush=True)\ntime.sleep(10)\n")
        do { _ = try CodexUsage.fetch(executable: denied, timeout: 3); preconditionFailure("Expected login error") }
        catch { precondition(error.localizedDescription.contains("Login required")) }
        let stalled = try mock("stalled", "time.sleep(10)\n")
        let started = Date()
        do { _ = try CodexUsage.fetch(executable: stalled, timeout: 0.2); preconditionFailure("Expected timeout") }
        catch { precondition(error.localizedDescription.contains("too long")) }
        precondition(Date().timeIntervalSince(started) < 2)
        let exited = try mock("exited", "sys.exit(1)\n")
        do { _ = try CodexUsage.fetch(executable: exited, timeout: 3); preconditionFailure("Expected exit error") }
        catch {}
        do { _ = try CodexUsage.parse([:]); preconditionFailure("Expected no-quota error") }
        catch {}
        let legacy = try CodexUsage.parse(["rateLimits": ["primary": ["windowDurationMins": 10080, "usedPercent": 120, "resetsAt": 1900000000]]])
        precondition(legacy.usedPercent == 100)
        let launcher = temp.appendingPathComponent(".local/bin/codex")
        let root = temp.appendingPathComponent(".local/lib/node_modules/@openai/codex")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let js = root.appendingPathComponent("bin/codex.js")
        try "#!/usr/bin/env node\n".write(to: js, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: js.path)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: js)
        #if arch(arm64)
        let relative = "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #else
        let relative = "node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        #endif
        let native = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: success, to: native)
        precondition(CodexUsage.executableURL(home: temp.path, environment: ["PATH": "/usr/bin:/bin"]) == native)
        print("PASS: npm native resolution; fragmented responses; quota selection; login errors; bounded timeout; early exit; absent quota; percent clamping")
    }
}
