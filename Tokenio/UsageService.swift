import Foundation
import Security

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

// MARK: - Keychain

private let keychainService = "tokenio"
private let keychainAccount = "session"

func keychainSave(service: String, account: String, data: Data) -> Bool {
    keychainDelete(service: service, account: account)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
    ]
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
}

func keychainLoad(service: String, account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

@discardableResult
func keychainDelete(service: String, account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    return SecItemDelete(query as CFDictionary) == errSecSuccess
}

// MARK: - Session storage

struct Session {
    let sessionKey: String
    let orgId: String
}

func loadSession() -> Session? {
    guard let data = keychainLoad(service: keychainService, account: keychainAccount),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let key = dict["sessionKey"], let org = dict["orgId"]
    else { return nil }
    return Session(sessionKey: key, orgId: org)
}

func saveSession(_ session: Session) {
    let dict: [String: String] = ["sessionKey": session.sessionKey, "orgId": session.orgId]
    if let data = try? JSONSerialization.data(withJSONObject: dict) {
        keychainSave(service: keychainService, account: keychainAccount, data: data)
    }
}

func clearSession() {
    keychainDelete(service: keychainService, account: keychainAccount)
}

// MARK: - OAuth fallback (Claude Code CLI)

func loadOAuthToken() -> String? {
    // Claude Code stores credentials under a different service name, no fixed account
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

    if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
        return nil // expired
    }
    return token
}

// MARK: - API

private let browserHeaders: [String: String] = [
    "accept": "*/*",
    "accept-language": "en-US,en;q=0.9",
    "content-type": "application/json",
    "anthropic-client-platform": "web_claude_ai",
    "anthropic-client-version": "1.0.0",
    "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "origin": "https://claude.ai",
    "referer": "https://claude.ai/settings/usage",
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "same-origin",
]

private func apiRequest(path: String, sessionKey: String) -> Any? {
    guard let url = URL(string: "https://claude.ai\(path)") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 15)
    for (k, v) in browserHeaders { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

    var result: Any?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data, let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
        if let prefix = String(data: data.prefix(5), encoding: .utf8),
           prefix.hasPrefix("<!DOC") || prefix.hasPrefix("<html") { return }
        result = try? JSONSerialization.jsonObject(with: data)
    }.resume()
    sem.wait()
    return result
}

private func apiRequestDict(path: String, sessionKey: String) -> [String: Any]? {
    apiRequest(path: path, sessionKey: sessionKey) as? [String: Any]
}

func validateAndGetOrg(sessionKey: String) -> String? {
    guard let arr = apiRequest(path: "/api/organizations", sessionKey: sessionKey) as? [[String: Any]],
          let first = arr.first,
          let uuid = first["uuid"] as? String
    else { return nil }
    return uuid
}

// MARK: - Fetch usage

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
    let now = Date()
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month], from: now)
    comps.month! += 1
    if comps.month! > 12 { comps.month = 1; comps.year! += 1 }
    comps.day = 1
    comps.timeZone = TimeZone(identifier: "UTC")
    return cal.date(from: comps)?.timeIntervalSince1970 ?? 0
}

func fetchUsageSessionKey(session: Session) -> UsageData? {
    let group = DispatchGroup()
    var usage: [String: Any]?
    var overage: [String: Any]?

    group.enter()
    DispatchQueue.global().async {
        usage = apiRequestDict(path: "/api/organizations/\(session.orgId)/usage", sessionKey: session.sessionKey)
        group.leave()
    }

    group.enter()
    DispatchQueue.global().async {
        overage = apiRequestDict(path: "/api/organizations/\(session.orgId)/overage_spend_limit", sessionKey: session.sessionKey)
        group.leave()
    }

    group.wait()

    guard let usage else { return nil }

    let ov = overage ?? [:]
    let usedCents = (ov["used_credits"] as? Int) ?? 0

    return UsageData(
        sessionPct: pct(usage["five_hour"] as? [String: Any]),
        sessionReset: rst(usage["five_hour"] as? [String: Any]),
        weeklyPct: pct(usage["seven_day"] as? [String: Any]),
        weeklyReset: rst(usage["seven_day"] as? [String: Any]),
        sonnetPct: pct(usage["seven_day_sonnet"] as? [String: Any]),
        sonnetReset: rst(usage["seven_day_sonnet"] as? [String: Any]),
        overagePct: (ov["utilization"] as? Double) ?? 0,
        overageReset: nextMonthTs(),
        extraDollars: Double(usedCents) / 100,
        extraEnabled: (ov["is_enabled"] as? Bool) ?? false
    )
}

func fetchUsageOAuth(token: String) -> UsageData? {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")

    var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let data, let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
        result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }.resume()
    sem.wait()

    guard let d = result else { return nil }
    let ex = (d["extra_usage"] as? [String: Any]) ?? [:]
    let usedCents = (ex["used_credits"] as? Int) ?? 0

    return UsageData(
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
    )
}

func fetchUsage() -> UsageResult {
    // Try sessionKey first
    if let session = loadSession() {
        if let data = fetchUsageSessionKey(session: session) {
            return .success(data)
        }
        clearSession()
        return .needsLogin
    }

    // Fallback: Claude Code OAuth
    if let token = loadOAuthToken() {
        if let data = fetchUsageOAuth(token: token) {
            return .success(data)
        }
        return .error("OAuth request failed")
    }

    return .needsLogin
}

// MARK: - Helpers

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
    return mins == 1 ? "1 min ago" : "\(mins) mins ago"
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
