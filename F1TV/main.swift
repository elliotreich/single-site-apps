import Cocoa
import WebKit

// F1TVPlayer — a minimal single-site browser for https://f1tv.formula1.com.
// Efficient WebKit shell (lighter than Chromium) with persistent login.
// Features: cookie archive, session keepalive, separate login window,
//           hide-on-close background persistence.

let kHomeURL = URL(string: "https://f1tv.formula1.com")!

// Real desktop Safari UA — most sites serve their proper player to Safari.
let kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.115 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Path to cookie archive — a plist of HTTPCookies that outlives WKWebView's
// own storage. We save auth cookies explicitly after login and restore them
// on every cold launch.
let kCookieArchivePath: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/com.elliot.f1tvplayer"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/Cookies.plist"
}()

// Translate an incoming f1tvweb:// URL into the real URL to load.
//   f1tvweb://https/example.com/path  -> https://example.com/path
func resolveDeepLink(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "f1tvweb" else { return nil }
    var rest = String(url.absoluteString.dropFirst("f1tvweb://".count))
    if rest.hasPrefix("https/") { rest = String(rest.dropFirst("https/".count)) }
    rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if rest.isEmpty { return kHomeURL }
    let full = rest.contains(".") ? "https://\(rest)" : "\(kHomeURL.scheme ?? "https")://\(kHomeURL.host ?? "")/\(rest)"
    return URL(string: full)
}

/// Read saved cookies from disk.
func loadCookieArchive() -> [HTTPCookie]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: kCookieArchivePath)),
          let cookies = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie],
          !cookies.isEmpty
    else { return nil }
    return cookies
}

/// Persist cookies to disk.
func saveCookieArchive(_ cookies: [HTTPCookie]) {
    let url = URL(fileURLWithPath: kCookieArchivePath)
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: cookies,
                                                       requiringSecureCoding: false)
    else { return }
    try? data.write(to: url, options: .atomic)
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var pendingURL: URL?

    // Login flow
    var loginWindow: NSWindow?
    var loginWebView: WKWebView?

    // Handle custom-scheme opens (f1tvweb:// links)
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
            if let err = err { NSLog("F1TV keepalive inject err: \(err)") }
        }
    }

    /// Log cookies for debugging.
    func logCookies(_ label: String = "") {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            if cookies.isEmpty {
                NSLog("F1TV cookie\(label): none found")
            } else {
                let domains = Set(cookies.map { $0.domain })
                NSLog("F1TV cookie\(label): \(cookies.count) cookies across \(domains.count) domains")
                for d in domains.sorted() {
                    let names = cookies.filter { $0.domain == d }.map(\.name).joined(separator: ", ")
                    NSLog("F1TV cookie\(label):   \(d) → \(cookies.filter { $0.domain == d }.count) cookies: \(names)")
                }
            }
        }
    }

    // ─── Cookie persistence ───────────────────────────────────────────────

    /// Save cookies to disk.
    func persistCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            guard !cookies.isEmpty else { return }
            saveCookieArchive(cookies)
            NSLog("F1TV persist: saved \(cookies.count) cookies")
        }
    }

    /// Restore cookies from disk, then load the target URL.
    func restoreCookiesAndLoad(_ target: URL) {
        guard let saved = loadCookieArchive() else {
            NSLog("F1TV restore: no cookie archive, loading fresh")
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
            NSLog("F1TV restore: injected \(saved.count) cookies from archive")
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
        lw.title = "Sign In — F1 TV"
        lw.center()
        lw.contentView = lwv

        loginWindow = lw
        loginWebView = lwv
        lw.delegate = self
        lw.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        lwv.load(URLRequest(url: kHomeURL))
        NSLog("F1TV login: opened login window")
    }

    // ─── App lifecycle ────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.default()

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
        window.title = "F1 TV"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("F1TVPlayerWindow")
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
            NSLog("F1TV didFinish: \(url)")
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
            // Login webview — detect successful auth by checking URL host
            let url = webView.url?.absoluteString ?? "?"
            NSLog("F1TV login didFinish: \(url)")
            if let host = webView.url?.host, host.contains(kHomeURL.host ?? "") {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self = self, !cookies.isEmpty else { return }
                    NSLog("F1TV login SUCCESS: \(cookies.count) cookies detected")
                    saveCookieArchive(cookies)
                    // Inject into main webview
                    let mainStore = self.webView.configuration.websiteDataStore.httpCookieStore
                    let group = DispatchGroup()
                    for c in cookies {
                        group.enter()
                        mainStore.setCookie(c) { group.leave() }
                    }
                    group.notify(queue: .main) {
                        NSLog("F1TV login: cookies injected into main webview, reloading")
                        self.webView.load(URLRequest(url: kHomeURL))
                    }
                    self.loginWindow?.close()
                    self.loginWindow = nil
                    self.loginWebView = nil
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        NSLog("F1TV\(label) didFail: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let label = (webView == self.webView) ? "" : " login"
        NSLog("F1TV\(label) didFailProvisional: \(error.localizedDescription)")
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
            loginWindow = nil
            loginWebView = nil
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
        appMenu.addItem(withTitle: "Hide F1 TV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit F1 TV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
