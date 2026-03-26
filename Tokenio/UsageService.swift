import Foundation
import Security
import LocalAuthentication
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

// MARK: - OAuth (Claude Code CLI credentials)

private let _cacheLock = NSLock()
private var _cachedToken: String? = nil
private var _cachedTokenExpiry: TimeInterval = 0

private func readClaudeCodeToken(interactive: Bool) -> String? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if !interactive {
        // Fail silently instead of showing a dialog — used for all background reads
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = ctx
    }
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
            log.info("OAuth token expired")
            return nil
        }
    } else {
        expiry = Date().timeIntervalSince1970 + 3600 // no expiry field — cache for 1h as a safe default
    }
    _cacheLock.lock()
    _cachedToken = token
    _cachedTokenExpiry = expiry
    _cacheLock.unlock()
    return token
}

// Cache-only check — no keychain access. Safe to call on the main thread.
func hasCachedToken() -> Bool {
    _cacheLock.lock()
    defer { _cacheLock.unlock() }
    return _cachedToken != nil && Date().timeIntervalSince1970 < _cachedTokenExpiry
}

// Silent read — used by background timer and visibility checks.
// Returns cached token if still valid, otherwise tries a no-dialog keychain read.
func loadOAuthToken() -> String? {
    _cacheLock.lock()
    let token = _cachedToken
    let expiry = _cachedTokenExpiry
    _cacheLock.unlock()
    if let token, Date().timeIntervalSince1970 < expiry {
        return token
    }
    return readClaudeCodeToken(interactive: false)
}

// Interactive read — shows keychain dialog if needed.
// Call only from explicit user actions (e.g. "Connect to Claude Code" menu item).
func loadOAuthTokenInteractive() -> String? {
    return readClaudeCodeToken(interactive: true)
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
            _cacheLock.lock()
            _cachedToken = nil
            _cachedTokenExpiry = 0
            _cacheLock.unlock()
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
    guard let token = loadOAuthToken() else { return .needsLogin }
    let result = fetchUsageOAuth(token: token)
    if case .success = result { log.info("Fetched usage via OAuth") }
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
