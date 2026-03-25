import AppKit
import WebKit

private let loginUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

private let allowedDomains: Set<String> = [
    "claude.ai",
    "accounts.google.com",
    "accounts.google.co.jp",
    "accounts.google.com.hk",
    "www.google.com",
    "appleid.apple.com",
    "login.microsoftonline.com",
    "github.com",
    "challenges.cloudflare.com",
]

class LoginWindow: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieTimer: Timer?
    private var onSuccess: ((_ sessionKey: String, _ orgId: String) -> Void)?
    private var onCancel: (() -> Void)?
    private var validationRetries = 0
    private let maxValidationRetries = 5

    init(onSuccess: @escaping (String, String) -> Void, onCancel: (() -> Void)? = nil) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let frame = NSRect(x: 0, y: 0, width: 480, height: 700)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.customUserAgent = loginUserAgent
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Log in to Claude"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: win
        )

        if let url = URL(string: "https://claude.ai/login") {
            wv.load(URLRequest(url: url))
        }

        win.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCookies()
        }
    }

    private func pollCookies() {
        guard let wv = webView else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            for cookie in cookies {
                if cookie.name == "sessionKey",
                   (cookie.domain.contains("claude.ai")),
                   !cookie.value.isEmpty {
                    self.stopPolling()
                    self.handleSessionKey(cookie.value)
                    return
                }
            }
        }
    }

    private func handleSessionKey(_ key: String) {
        DispatchQueue.global().async { [weak self] in
            guard let orgId = validateAndGetOrg(sessionKey: key) else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.validationRetries += 1
                    if self.validationRetries >= self.maxValidationRetries {
                        self.stopPolling()
                        let alert = NSAlert()
                        alert.messageText = "Login Failed"
                        alert.informativeText = "Could not validate your session. Please try again."
                        alert.alertStyle = .warning
                        alert.runModal()
                        self.close()
                        self.onCancel?()
                    } else {
                        self.startPolling()
                    }
                }
                return
            }
            saveSession(Session(sessionKey: key, orgId: orgId))
            DispatchQueue.main.async {
                self?.close()
                self?.onSuccess?(key, orgId)
            }
        }
    }

    private func startPolling() {
        cookieTimer?.invalidate()
        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCookies()
        }
    }

    private func stopPolling() {
        cookieTimer?.invalidate()
        cookieTimer = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        stopPolling()
        onCancel?()
    }

    func close() {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let host = navigationAction.request.url?.host else {
            decisionHandler(.allow)
            return
        }
        let allowed = allowedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
        if !allowed { log.info("Blocked navigation to: \(host)") }
        decisionHandler(allowed ? .allow : .cancel)
    }
}
