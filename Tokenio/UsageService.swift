import Foundation
import Security
import os

let log = Logger(subsystem: "com.tokenio.app", category: "general")

// MARK: - Data model

struct UsageData {
    var sessionPct: Double = 0
    var sessionReset: TimeInterval = 0
    var weeklyPct: Double = 0
    var weeklyReset: TimeInterval = 0
    var sonnetPct: Double = 0
    var sonnetReset: TimeInterval = 0
    var overagePct: Double = 0
    var overageReset: TimeInterval = 0
    var extraDollars: Double = 0
    var extraEnabled: Bool = false
}

enum UsageResult {
    case success(UsageData)
    case needsLogin
    case error(String)
}

// MARK: - Tokenio-owned OAuth storage

struct StoredOAuthAccess: Codable {
    var accessToken: String
    var expiresAt: TimeInterval     // seconds since epoch
    var subscriptionType: String?
}

private let storedAccessKey = "storedOAuthAccess"

@discardableResult
func saveStoredAccess(_ access: StoredOAuthAccess) -> Bool {
    guard let data = try? JSONEncoder().encode(access) else { return false }
    UserDefaults.standard.set(data, forKey: storedAccessKey)
    return true
}

func loadStoredAccess() -> StoredOAuthAccess? {
    guard let data = UserDefaults.standard.data(forKey: storedAccessKey),
          let stored = try? JSONDecoder().decode(StoredOAuthAccess.self, from: data)
    else { return nil }
    if stored.expiresAt < Date().timeIntervalSince1970 {
        log.info("Stored access token expired")
        return nil
    }
    return stored
}

func clearStoredAccess() {
    UserDefaults.standard.removeObject(forKey: storedAccessKey)
}

// One-time interactive import from Claude Code's keychain.
// This is the ONLY code path that touches "Claude Code-credentials".
func importClaudeCodeAccessInteractive() -> StoredOAuthAccess? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = creds["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { return nil }

    let expiry: TimeInterval
    if let exp = oauth["expiresAt"] as? Double {
        expiry = exp / 1000
        if expiry < Date().timeIntervalSince1970 {
            log.info("Claude Code token already expired, skipping import")
            return nil
        }
    } else {
        expiry = Date().timeIntervalSince1970 + 3600
    }

    let access = StoredOAuthAccess(
        accessToken: token,
        expiresAt: expiry,
        subscriptionType: oauth["subscriptionType"] as? String
    )
    guard saveStoredAccess(access) else {
        log.error("Failed to save imported access token to Tokenio keychain")
        return nil
    }
    log.info("Imported Claude Code access token (expires in \(Int((expiry - Date().timeIntervalSince1970) / 3600))h)")
    return access
}

// MARK: - Usage snapshot persistence

private let snapshotKey = "lastUsageSnapshot"
private let snapshotTimeKey = "lastUsageSnapshotTime"

func saveSnapshot(_ data: UsageData) {
    let dict: [String: Any] = [
        "sessionPct": data.sessionPct, "sessionReset": data.sessionReset,
        "weeklyPct": data.weeklyPct, "weeklyReset": data.weeklyReset,
        "sonnetPct": data.sonnetPct, "sonnetReset": data.sonnetReset,
        "overagePct": data.overagePct, "overageReset": data.overageReset,
        "extraDollars": data.extraDollars, "extraEnabled": data.extraEnabled,
    ]
    UserDefaults.standard.set(dict, forKey: snapshotKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: snapshotTimeKey)
}

func loadSnapshot() -> (UsageData, TimeInterval)? {
    guard let dict = UserDefaults.standard.dictionary(forKey: snapshotKey) else { return nil }
    let ts = UserDefaults.standard.double(forKey: snapshotTimeKey)
    guard ts > 0 else { return nil }
    let data = UsageData(
        sessionPct: dict["sessionPct"] as? Double ?? 0,
        sessionReset: dict["sessionReset"] as? Double ?? 0,
        weeklyPct: dict["weeklyPct"] as? Double ?? 0,
        weeklyReset: dict["weeklyReset"] as? Double ?? 0,
        sonnetPct: dict["sonnetPct"] as? Double ?? 0,
        sonnetReset: dict["sonnetReset"] as? Double ?? 0,
        overagePct: dict["overagePct"] as? Double ?? 0,
        overageReset: dict["overageReset"] as? Double ?? 0,
        extraDollars: dict["extraDollars"] as? Double ?? 0,
        extraEnabled: dict["extraEnabled"] as? Bool ?? false
    )
    return (data, ts)
}

// MARK: - API

private func fetchUsageOAuth(token: String) -> UsageResult {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        return .error("Bad URL")
    }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/2.5.0", forHTTPHeaderField: "User-Agent")

    var result: UsageResult = .error("Request timed out")
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, error in
        defer { sem.signal() }
        if let error {
            result = .error(error.localizedDescription)
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            result = .error("No response")
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            log.warning("Auth failure (\(http.statusCode)) on OAuth endpoint")
            result = .needsLogin
            return
        }
        guard (200...299).contains(http.statusCode) else {
            result = .error("HTTP \(http.statusCode)")
            return
        }
        guard let data else {
            result = .error("No data")
            return
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result = .error("Invalid JSON")
            return
        }
        let ex = (d["extra_usage"] as? [String: Any]) ?? [:]
        let usedCents = (ex["used_credits"] as? Int) ?? 0
        result = .success(UsageData(
            sessionPct: pct(d["five_hour"] as? [String: Any]),
            sessionReset: rst(d["five_hour"] as? [String: Any]),
            weeklyPct: pct(d["seven_day"] as? [String: Any]),
            weeklyReset: rst(d["seven_day"] as? [String: Any]),
            sonnetPct: pct(d["seven_day_sonnet"] as? [String: Any]),
            sonnetReset: rst(d["seven_day_sonnet"] as? [String: Any]),
            overagePct: (ex["utilization"] as? Double) ?? 0,
            overageReset: nextMonthTs(),
            extraDollars: Double(usedCents) / 100,
            extraEnabled: (ex["is_enabled"] as? Bool) ?? false
        ))
    }.resume()
    sem.wait()
    return result
}

func fetchUsage() -> UsageResult {
    guard let stored = loadStoredAccess() else { return .needsLogin }
    let result = fetchUsageOAuth(token: stored.accessToken)
    if case .success(let data) = result {
        log.info("Fetched usage via OAuth")
        saveSnapshot(data)
    }
    if case .needsLogin = result { clearStoredAccess() }
    return result
}

// MARK: - Helpers

private func parseISO(_ str: String?) -> TimeInterval {
    guard let str, !str.isEmpty else { return 0 }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: str) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: str)?.timeIntervalSince1970 ?? 0
}

private func pct(_ block: [String: Any]?) -> Double {
    (block?["utilization"] as? Double) ?? 0
}

private func rst(_ block: [String: Any]?) -> TimeInterval {
    parseISO(block?["resets_at"] as? String)
}

private func nextMonthTs() -> TimeInterval {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date()
    var comps = cal.dateComponents([.year, .month], from: now)
    comps.month! += 1
    if comps.month! > 12 { comps.month = 1; comps.year! += 1 }
    comps.day = 1
    return cal.date(from: comps)?.timeIntervalSince1970 ?? 0
}

func elapsedPct(resetTs: TimeInterval, windowSecs: TimeInterval) -> Double {
    guard resetTs > 0 else { return 50.0 }
    let elapsed = Date().timeIntervalSince1970 - (resetTs - windowSecs)
    return max(0, min(100, elapsed / windowSecs * 100))
}

func fmtAgo(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "—" }
    let secs = Int(Date().timeIntervalSince1970 - ts)
    if secs < 60 { return "just now" }
    let mins = secs / 60
    if mins < 60 { return mins == 1 ? "1 min ago" : "\(mins) mins ago" }
    let hrs = mins / 60
    return hrs == 1 ? "1h ago" : "\(hrs)h ago"
}

func fmtReset(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "?" }
    let d = ts - Date().timeIntervalSince1970
    if d <= 0 { return "now" }
    let h = Int(d) / 3600
    let m = (Int(d) % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
