import Cocoa
import WebKit

// Shared process pool so main and login windows share cookies/storage
let sharedPool = WKProcessPool()

// AppleTVPlayer — a minimal single-site browser for tv.apple.com.
// Efficient WebKit shell (lighter than Chromium) that stays logged into an Apple ID.
// NOTE: browser playback of Apple TV+ is quality-capped vs the native TV app; this
// trades max quality for efficiency + persistent login, which is the user's choice.

let kHomeURL = URL(string: "https://tv.apple.com")!

// Real desktop Safari UA — Apple serves its proper web player to Safari.
let kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.115 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Path to our cookie archive — a plist of HTTPCookies that outlives WKWebView's
// own storage. This is the keystone of persistent login: we save auth cookies
// explicitly after login and restore them on every cold launch.
let kCookieArchivePath: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/com.elliot.appletvplayer"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/Cookies.plist"
}()

/// Apple ID auth cookies that signal an active session. If these exist on
/// the apple.com domain, Apple's SSO considers the user logged in.
let kAppleAuthCookies: Set<String> = [
    "myacinfo",      // Apple ID account info token
    "itctx",         // iCloud/auth context token
    "ams_sub",       // Apple Media Services subscription token
    "aasp",          // Apple auth session profile
    "dqsid",         // Directory services session ID
    "co_did",        // Cross-domain identifier
    "co_sid",        // Cross-domain session ID
]

// Translate an incoming appletvweb:// URL into the real tv.apple.com URL to load.
//   appletvweb://https/tv.apple.com/us/movie/...  -> https://tv.apple.com/us/movie/...
//   appletvweb://show/umc.cmc.xxxx                -> https://tv.apple.com/show/umc.cmc.xxxx
// The userscript uses the full-path (https/) form; the others are tolerated defensively.
func resolveDeepLink(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "appletvweb" else { return nil }
    var rest = String(url.absoluteString.dropFirst("appletvweb://".count))
    if rest.hasPrefix("https/") { rest = String(rest.dropFirst("https/".count)) }
    rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if rest.isEmpty { return kHomeURL }
    let full = rest.hasPrefix("tv.apple.com") ? "https://\(rest)" : "https://tv.apple.com/\(rest)"
    return URL(string: full)
}

/// Read saved cookies from disk. Returns nil if no archive exists.
func loadCookieArchive() -> [HTTPCookie]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: kCookieArchivePath)),
          let cookies = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie],
          !cookies.isEmpty
    else { return nil }
    return cookies
}

/// Persist cookies to disk, replacing the archive atomically.
func saveCookieArchive(_ cookies: [HTTPCookie]) {
    let url = URL(fileURLWithPath: kCookieArchivePath)
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: cookies,
                                                       requiringSecureCoding: false)
    else { return }
    try? data.write(to: url, options: .atomic)
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate, WKHTTPCookieStoreObserver {
    var window: NSWindow!
    var webView: WKWebView!
    // A deep link can arrive before the webView exists (cold launch). Buffer it and
    // load it once didFinishLaunching has built the view.
    var pendingURL: URL?

    // Login flow
    var loginWindow: NSWindow?
    var loginWebView: WKWebView?

    // macOS hands custom-scheme opens here: queued before didFinishLaunching on cold
    // launch, delivered live while already running.
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

    /// Ping Apple's session endpoint every 10 minutes so the auth cookie stays fresh
    /// on the server side. WKWebView keeps the cookie in memory; this prevents
    /// server-side TTL from logging us out.
    func injectKeepalive() {
        let js = """
        (function(){
            if (window.__atvKeepalive) return;
            window.__atvKeepalive = setInterval(function(){
                fetch('/api/v1/me/profile', {credentials:'include', cache:'no-store', redirect:'manual'})
                    .catch(function(){});
            }, 10 * 60 * 1000);
        })();
        """
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { NSLog("ATV keepalive inject err: \(err)") }
        }
    }

    /// Log cookies for debugging session persistence.
    func clearStaleReeseIfNeeded() {
        let js = "(function(){ try { const raw=localStorage.getItem('reese84'); if(!raw) return; const data=JSON.parse(raw); if(data.renewTime && Date.now() > data.renewTime + (data.renewInSec||778)*1000) { console.log('clearing stale reese84'); localStorage.removeItem('reese84'); } } catch(e){} })();";
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func logCookies(_ label: String = "") {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter { $0.domain.contains("apple.com") || $0.domain.contains("tv.apple") }
            for c in relevant {
                let isAppleAuth = kAppleAuthCookies.contains(c.name)
                NSLog("ATV cookie\(label): \(c.name)=\(c.value.prefix(30))... domain=\(c.domain) expires=\(String(describing: c.expiresDate)) session=\(c.isSessionOnly) auth=\(isAppleAuth)")
            }
            if relevant.isEmpty {
                NSLog("ATV cookie\(label): NO apple.com cookies found (logged out)")
            }
        }
    }

    // ─── Cookie persistence helpers ────────────────────────────────────────

    /// Save all apple-domain cookies from the main webview to disk.
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        persistCookies()
    }

    func persistCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter { $0.domain.contains("apple.com") || $0.domain.contains("tv.apple") }
            guard !relevant.isEmpty else { return }
            saveCookieArchive(relevant)
            // Log auth cookie presence for debugging
            let authCookies = relevant.filter { kAppleAuthCookies.contains($0.name) }
            if !authCookies.isEmpty {
                NSLog("ATV persist: saved \(authCookies.count) auth cookies (\(authCookies.map(\.name).joined(separator: ", ")))")
            }
        }
    }

    /// Restore cookies from disk into the main webview, then load the target URL.
    func restoreCookiesAndLoad(_ target: URL) {
        guard let saved = loadCookieArchive() else {
            NSLog("ATV restore: no cookie archive, loading fresh")
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
            NSLog("ATV restore: injected \(saved.count) cookies from archive \(saved.filter { kAppleAuthCookies.contains($0.name) }.count) auth")
            self?.webView.load(URLRequest(url: target))
        }
    }

    // ─── Login window ──────────────────────────────────────────────────────

    /// Open a separate login window so the user can sign into Apple ID.
    /// After successful auth, cookies are saved to the archive and the main
    /// webview reloads with the session.
    @objc func openLoginWindow() {
        // If a login window is already open, just bring it forward
        if let existing = loginWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.default()
        // Disable ITP for the login webview too (same reason as main)
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
        lw.title = "Sign In to Apple TV"
        lw.center()
        lw.contentView = lwv

        // Store refs so the delegate callbacks can reach them
        loginWindow = lw
        loginWebView = lwv

        lw.delegate = self
        lw.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        lwv.load(URLRequest(url: kHomeURL))
        NSLog("ATV login: opened login window")
    }

    // ─── App lifecycle ─────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()

        // PERSISTENT login. Use the .default() store — the same one Spectrum uses,
        // which persists fine. The previous WKWebsiteDataStore(forIdentifier:) path
        // silently drops the Apple ID session on macOS 26; that was the logout cause.
        // .default() still isolates per-app: a non-sandboxed app keys its data by
        // bundle id under ~/Library/WebKit/<bundle-id>/, so this stays separate from
        // Spectrum's cookies.
        let store = WKWebsiteDataStore.default()

        // Apple ID login is cross-domain: idmsa.apple.com / appleid.apple.com set the
        // auth cookies that tv.apple.com depends on. WebKit's Intelligent Tracking
        // Prevention treats that as cross-site tracking and purges those cookies,
        // which logs you out after a while. Turn ITP off so the session survives.
        // No public API for this, so use the private selector defensively — if it
        // ever disappears, login still works, it just may expire again.
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
        window.title = "Apple TV"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("AppleTVPlayerWindow")
        window.contentView = webView
        webView.frame = window.contentView!.bounds

        buildMenu()
        // If launched by a appletvweb:// link, open that; otherwise the home page.
        // Restore cookies from disk before loading, so the session survives restart.
        restoreCookiesAndLoad(pendingURL ?? kHomeURL)
        pendingURL = nil
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // ─── Navigation delegate ───────────────────────────────────────────────

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"

        if webView == self.webView {
            // ── Main webview ──
            NSLog("ATV didFinish: \(url)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let cv = self.window.contentView else { return }
                self.webView.frame = cv.bounds
                self.webView.needsDisplay = true
                cv.needsDisplay = true
                self.window.displayIfNeeded()
            }
            webView.evaluateJavaScript("({u:location.href, t:document.title, bodyLen:document.body? document.body.innerText.length:-1, html:document.documentElement.outerHTML.length})") { result, err in
                NSLog("ATV DOM probe: \(String(describing: result)) err=\(String(describing: err))")
            }
            // Session persistence
            logCookies()
            clearStaleReeseIfNeeded()
            injectKeepalive()
            persistCookies()
        } else if webView == loginWebView {
            // ── Login webview ──
            NSLog("ATV login didFinish: \(url)")

            // Detect successful auth: we're back on tv.apple.com AND auth cookies exist
            if url.contains("tv.apple.com") {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self = self else { return }
                    let appleCookies = cookies.filter { $0.domain.contains("apple.com") || $0.domain.contains("tv.apple") }
                    let authCookies = appleCookies.filter { kAppleAuthCookies.contains($0.name) }
                    if !authCookies.isEmpty {
                        NSLog("ATV login SUCCESS: \(authCookies.count) auth cookies detected")
                        // Save cookies to archive
                        saveCookieArchive(appleCookies)
                        // Inject into main webview
                        let mainStore = self.webView.configuration.websiteDataStore.httpCookieStore
                        let group = DispatchGroup()
                        for c in appleCookies {
                            group.enter()
                            mainStore.setCookie(c) { group.leave() }
                        }
                        group.notify(queue: .main) {
                            NSLog("ATV login: cookies injected into main webview, reloading")
                            self.webView.load(URLRequest(url: kHomeURL))
                        }
                        // Close login window
                        self.loginWindow?.close()
                        self.loginWindow = nil
                        self.loginWebView = nil
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        NSLog("ATV\(label) didFail: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        NSLog("ATV\(label) didFailProvisional: \(error.localizedDescription)")
    }

    // ─── Window delegate ───────────────────────────────────────────────────

    // Save cookies on quit so the archive has the latest session state.
    func applicationWillTerminate(_ notification: Notification) {
        persistCookies()
    }

    // Hide instead of quit on window close — keeps WKWebView alive and cookies
    // in memory so the session survives between "launches."
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == window {
            // Main window: hide and save cookies
            persistCookies()
            sender.orderOut(nil)
            return false
        }
        // Login window: allow close, clean up refs
        if sender == loginWindow {
            loginWindow = nil
            loginWebView = nil
        }
        return true
    }

    // Clicking the dock icon brings the hidden window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ─── Menu ──────────────────────────────────────────────────────────────

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sign In…", action: #selector(openLoginWindow), keyEquivalent: "i")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Apple TV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Apple TV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
