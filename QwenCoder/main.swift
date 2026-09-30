import Cocoa
import WebKit

// Shared process pool so the main and sign-in windows share cookies/storage.
let sharedPool = WKProcessPool()

// QwenCoderPlayer — a minimal single-site browser for https://coder.qwen.ai/.
// Efficient WebKit shell (lighter than Chromium) with persistent login.
// Features: cookie archive, session keepalive, separate login window,
//           hide-on-close background persistence.

let kHomeURL = URL(string: "https://coder.qwen.ai/")!

// Real desktop Safari UA — most sites serve their proper player to Safari.
let kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.115 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Path to cookie archive — a plist of HTTPCookies that outlives WKWebView's
// own storage. We save auth cookies explicitly after login and restore them
// on every cold launch.
let kCookieArchivePath: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/com.elliot.qwencoderplayer"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // The archive contains authentication cookies; keep both the directory
    // and the file private to this macOS user.
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    return dir + "/Cookies.plist"
}()

// Translate an incoming qwencoderweb:// URL into the real URL to load.
//   qwencoderweb://https/example.com/path  -> https://example.com/path
func resolveDeepLink(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "qwencoderweb" else { return nil }
    var rest = String(url.absoluteString.dropFirst("qwencoderweb://".count))
    if rest.hasPrefix("https/") { rest = String(rest.dropFirst("https/".count)) }
    rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if rest.isEmpty { return kHomeURL }
    let full = rest.contains(".") ? "https://\(rest)" : "\(kHomeURL.scheme ?? "https")://\(kHomeURL.host ?? "")/\(rest)"
    return URL(string: full)
}

/// Convert a cookie to a property-list-safe record. HTTPCookie itself does
/// not adopt NSSecureCoding on current macOS, so archiving HTTPCookie objects
/// directly is not a reliable cold-launch format.
func cookieRecord(from cookie: HTTPCookie) -> [String: Any] {
    var record: [String: Any] = [
        "name": cookie.name,
        "value": cookie.value,
        "domain": cookie.domain,
        "path": cookie.path,
        "version": cookie.version,
        "secure": cookie.isSecure,
        "httpOnly": cookie.isHTTPOnly,
        "sessionOnly": cookie.isSessionOnly
    ]
    if let expires = cookie.expiresDate {
        record["expires"] = expires.timeIntervalSince1970
    }
    if let sameSite = cookie.sameSitePolicy {
        record["sameSitePolicy"] = sameSite
    }
    return record
}

/// Rebuild a cookie from a persisted record.
func cookie(from record: [String: Any]) -> HTTPCookie? {
    guard let name = record["name"] as? String,
          let value = record["value"] as? String,
          let domain = record["domain"] as? String,
          let path = record["path"] as? String
    else { return nil }

    var properties: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: path,
        .version: record["version"] as? Int ?? 0,
        .secure: (record["secure"] as? Bool ?? false) ? "TRUE" : "FALSE"
    ]
    if let timestamp = record["expires"] as? Double {
        properties[.expires] = Date(timeIntervalSince1970: timestamp)
    }
    if record["httpOnly"] as? Bool == true {
        properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
    }
    if let sameSite = record["sameSitePolicy"] as? String {
        properties[.sameSitePolicy] = sameSite
    }
    return HTTPCookie(properties: properties)
}

/// Read saved cookies from disk.
func loadCookieArchive() -> [HTTPCookie]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: kCookieArchivePath)),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let payload = plist as? [String: Any],
          let rawRecords = payload["cookies"] as? [Any]
    else { return nil }
    let cookies = rawRecords.compactMap { $0 as? [String: Any] }.compactMap(cookie(from:))
    return cookies.isEmpty ? nil : cookies
}

/// Persist cookies to disk.
func saveCookieArchive(_ cookies: [HTTPCookie]) {
    let url = URL(fileURLWithPath: kCookieArchivePath)
    let payload: [String: Any] = [
        "version": 2,
        "cookies": cookies.map { cookieRecord(from: $0) }
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: payload,
                                                         format: .binary,
                                                         options: 0)
    else { return }
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate, WKHTTPCookieStoreObserver {
    var window: NSWindow!
    var webView: WKWebView!
    var pendingURL: URL?

    // Login flow
    var loginWindow: NSWindow?
    var loginWebView: WKWebView?

    // Handle custom-scheme opens (qwencoderweb:// links)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let target = urls.lazy.compactMap({ resolveDeepLink($0) }).first else { return }
        if webView != nil {
            webView.load(URLRequest(url: target))
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            pendingURL = target
        }
    }

    /// Ping the site periodically to keep the server-side session alive.
    func injectKeepalive() {
        let js = """
        (function(){
            if (window.__siteKeepalive) return;
            window.__siteKeepalive = setInterval(function(){
                fetch('/', {credentials:'include', cache:'no-store', redirect:'manual'})
                    .catch(function(){});
            }, 10 * 60 * 1000);
        })();
        """
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { print("QwenCoder keepalive inject err: \(err)") }
        }
    }

    /// Log cookies for debugging.
    func logCookies(_ label: String = "") {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            if cookies.isEmpty {
                print("QwenCoder cookie\(label): none found")
            } else {
                let domains = Set(cookies.map { $0.domain })
                print("QwenCoder cookie\(label): \(cookies.count) cookies across \(domains.count) domains")
                for d in domains.sorted() {
                    let names = cookies.filter { $0.domain == d }.map(\.name).joined(separator: ", ")
                    print("QwenCoder cookie\(label):   \(d) → \(cookies.filter { $0.domain == d }.count) cookies: \(names)")
                }
            }
        }
    }

    // ─── Cookie persistence ───────────────────────────────────────────────

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        persistCookies()
    }

    /// Save cookies to disk.
    func persistCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            guard !cookies.isEmpty else { return }
            saveCookieArchive(cookies)
            print("QwenCoder persist: saved \(cookies.count) cookies")
        }
    }

    /// Restore cookies from disk, then load the target URL.
    func restoreCookiesAndLoad(_ target: URL) {
        guard let saved = loadCookieArchive() else {
            print("QwenCoder restore: no cookie archive, loading fresh")
            webView.load(URLRequest(url: target))
            return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in saved {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            print("QwenCoder restore: injected \(saved.count) cookies from archive")
            self?.webView.load(URLRequest(url: target))
        }
    }

    // ─── Login window ─────────────────────────────────────────────────────

    @objc func openLoginWindow() {
        if let existing = loginWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let config = WKWebViewConfiguration()
        config.processPool = sharedPool
        let store = WKWebsiteDataStore.default()
        // Disable ITP for login window too (keeps cross-domain auth cookies alive)
        let sel = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if store.responds(to: sel) {
            store.perform(sel, with: false as NSNumber)
        }
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let lwv = WKWebView(frame: .zero, configuration: config)
        lwv.customUserAgent = kUserAgent
        lwv.navigationDelegate = self
        lwv.autoresizingMask = [.width, .height]

        let lw = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        lw.title = "Sign In — Qwen Coder"
        lw.center()
        lw.contentView = lwv

        loginWindow = lw
        loginWebView = lwv
        lw.delegate = self
        lw.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lwv.load(URLRequest(url: kHomeURL))
        print("QwenCoder login: opened login window")
    }

    /// The landing page always has a session cookie, so host/cookie checks
    /// alone would close this window before the user can press Log in.
    func loginPageLooksAuthenticated(_ webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
            const candidates = Array.from(document.querySelectorAll('button, a, [role="button"]'));
            return !candidates.some(function(element){
                const style = window.getComputedStyle(element);
                const box = element.getBoundingClientRect();
                const visible = style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
                const label = (element.innerText || element.getAttribute('aria-label') || '').trim();
                return visible && /^(log\\s*in|login|sign\\s*up)$/i.test(label);
            });
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion(result as? Bool ?? false)
        }
    }

    /// Keep the auxiliary window alive and take it off-screen. On macOS 26,
    /// closing a WebKit-backed window can race AppKit's transform animation
    /// teardown and crash in `NSWindowTransformAnimation.dealloc`.
    func hideLoginWindow() {
        loginWindow?.orderOut(nil)
    }

    // ─── App lifecycle ────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.processPool = sharedPool
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.add(self)

        // Disable ITP for persistent cross-domain auth cookies
        let sel = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if store.responds(to: sel) {
            store.perform(sel, with: false as NSNumber)
        }
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = kUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 760)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Qwen Coder"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("QwenCoderPlayerWindow")
        window.contentView = webView
        webView.frame = window.contentView!.bounds

        buildMenu()
        restoreCookiesAndLoad(pendingURL ?? kHomeURL)
        pendingURL = nil
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // ─── Navigation delegate ──────────────────────────────────────────────

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == self.webView {
            // Main webview
            let url = webView.url?.absoluteString ?? "?"
            print("QwenCoder didFinish: \(url)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let cv = self.window.contentView else { return }
                self.webView.frame = cv.bounds
                self.webView.needsDisplay = true
                cv.needsDisplay = true
                self.window.displayIfNeeded()
            }
            logCookies()
            injectKeepalive()
            persistCookies()
        } else if webView == loginWebView {
            // Login webview — wait until the visible sign-in controls disappear.
            let url = webView.url?.absoluteString ?? "?"
            print("QwenCoder login didFinish: \(url)")
            if let host = webView.url?.host, host.contains(kHomeURL.host ?? "") {
                loginPageLooksAuthenticated(webView) { [weak self] authenticated in
                    guard authenticated, let self = self else { return }
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        guard !cookies.isEmpty else { return }
                        print("QwenCoder login SUCCESS: \(cookies.count) cookies detected")
                        saveCookieArchive(cookies)
                        // Inject into main webview
                        let mainStore = self.webView.configuration.websiteDataStore.httpCookieStore
                        let group = DispatchGroup()
                        for c in cookies {
                            group.enter()
                            mainStore.setCookie(c) { group.leave() }
                        }
                        group.notify(queue: .main) {
                            print("QwenCoder login: cookies injected into main webview, reloading")
                            self.webView.load(URLRequest(url: kHomeURL))
                        }
                        self.hideLoginWindow()
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        print("QwenCoder\(label) didFail: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        print("QwenCoder\(label) didFailProvisional: \(error.localizedDescription)")
    }

    // ─── Window delegate ──────────────────────────────────────────────────

    func applicationWillTerminate(_ notification: Notification) {
        persistCookies()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == window {
            persistCookies()
            sender.orderOut(nil)
            return false
        }
        if sender == loginWindow {
            hideLoginWindow()
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ─── Menu ─────────────────────────────────────────────────────────────

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sign In…", action: #selector(openLoginWindow), keyEquivalent: "i")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Qwen Coder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Qwen Coder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Enter Full Screen",
                                  action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func reload() { webView.reload() }
    @objc func goHome() { webView.load(URLRequest(url: kHomeURL)) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
