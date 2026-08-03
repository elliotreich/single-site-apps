# single-site-apps — efficient native WebKit wrappers

Minimal native macOS apps that wrap one streaming site each in a `WKWebView`.
Purpose: **far lighter than a browser tab** (WebKit, not Chromium → hardware
VideoToolbox decode + FairPlay) and **persistent login**. Each is a single
`main.swift` compiled to a signed `.app` — no Xcode project, no dependencies.

Built 2026-06-14. Apple Silicon, macOS 26.5, Swift 6.3.

## Apps

| Dir | Installed as | Wraps | Notes |
|---|---|---|---|
| `Spectrum/` | `/Applications/Spectrum.app` | `watch.spectrum.net/livetv` | Works great. Logged in, persists. ~52 MB RAM idle, ~177 MB streaming (vs Brave ~944 MB). HW-decoded. |
| `AppleTV/`  | `/Applications/Apple TV Web.app` | `tv.apple.com` | For watching mom's Apple TV+ via her Apple ID in-app. See caveats below. |

> The **YouTube** app is a separate, much larger native project at
> `~/syncthing-shared/dev/youtube/` (not a wrapper — full SwiftUI + yt-dlp + AVPlayer).

## Build / install

```bash
./build.sh Spectrum "Spectrum"
./build.sh AppleTV  "Apple TV Web"
```
Compiles, bundles, ad-hoc code-signs (required for WKWebView networking +
FairPlay on modern macOS), and registers with LaunchServices.

## How they work (the important bits)

- **WKWebView + real Safari user-agent** so the site serves its standard player.
- **Code-signing is mandatory** — unsigned, WebKit networking/DRM silently fails.
- **Persistent login**: a named on-disk `WKWebsiteDataStore(forIdentifier:)`
  (macOS 14+) so cookies/2FA-trusted sessions survive relaunches. Data lives at
  `~/Library/WebKit/<bundle-id>/`.
- `mediaTypesRequiringUserActionForPlayback = []`, PiP + AirPlay + element
  fullscreen enabled. ⌃⌘F = fullscreen, ⌘R = reload, ⌘0 = home.

## Quality ceiling — read before assuming "low quality = bug"

DRM sites cap quality by **playback path**, not by player. Browser/WebKit
playback gets the *software-Widevine / lower* tier; the *native* app gets the
hardware-secure high tier.
- **Spectrum**: the web path IS the normal path → full quality. 
- **Apple TV+**: the web path is **capped (~720p, no Dolby)**. Only Apple's
  native TV app gets 4K/Atmos. This wrapper is chosen for **efficiency +
  persistent login**, knowingly trading the quality ceiling. Not a bug.

## Apple TV app — known issues / status (2026-06-14)

- **Computer-use can't screenshot it** — anything named "Apple TV" is
  policy-blocked for the automation harness. Verify visually by hand.
- **White-screen on first open**: DOM probe confirmed the page fully loads and
  renders (416 KB DOM, no JS error) — so it's a **first-paint timing** issue,
  not a load failure. Added a relayout/`displayIfNeeded()` nudge in `didFinish`.
  If still blank: prime suspect is the `forIdentifier` data store on macOS 26;
  fallback = switch to a persistent store at a custom path (keeps login) or
  `.default()` (loses per-app isolation but paints reliably).
- **Login**: sign in with mom's Apple ID + the 2FA code sent to HER trusted
  device. Don't auto-fill credentials — it's not Elliot's account.

## Logout fix (2026-06-28)

The app used to log itself out. Two causes, both fixed in `main.swift`:
1. `WKWebsiteDataStore(forIdentifier:)` silently drops the session on macOS 26.
   Switched to `.default()` (the store Spectrum uses, which persists fine). It
   still isolates per-app — non-sandboxed apps key data by bundle id under
   `~/Library/WebKit/<bundle-id>/`, so this stays separate from Spectrum.
2. Apple ID login is cross-domain (`idmsa.apple.com` sets the cookies
   `tv.apple.com` relies on). WebKit's ITP treated that as tracking and purged
   them. Disabled ITP via the private `_setResourceLoadStatisticsEnabled:`
   selector (guarded, so login still works if the selector ever vanishes).

Switching stores means a **one-time re-login** — the old `forIdentifier:` session
doesn't migrate.

## Routing tv.apple.com links here instead of the native TV.app (2026-06-28)

The native Apple TV app is tied to the Mac's *system* iCloud, which is the wrong
account. So tv.apple.com's "Open in Apple TV" links go to the wrong place. Fix:

- The wrapper registers a custom scheme **`appletvweb://`** (`CFBundleURLTypes`
  in `Info.plist`) and handles `application(_:open:)` — cold launch and live,
  with a `pendingURL` buffer. `resolveDeepLink()` maps
  `appletvweb://https/tv.apple.com/…` back to the real `https://` URL.
- Raycast also claims the scheme, so the install set us as default handler:
  `LSSetDefaultHandlerForURLScheme("appletvweb", "com.elliot.appletvplayer")`.
  Re-run that (a 6-line `swift` snippet) if Raycast ever steals it back.
- **Brave side: `open-in-web-app.user.js`** (a Tampermonkey userscript in this
  dir). It drops a floating "▶ Open in Apple TV Web app" button on every
  tv.apple.com page that rewrites the current URL to `appletvweb://…` and fires
  it. Install: open Tampermonkey → Create new script → paste the file →
  save. (We use our own button rather than hijacking Apple's banner, which is
  conditional/shadow-DOM and brittle.)

## Adding a new site

Copy a dir, edit `kHomeURL` + the bundle id/name in `main.swift` and
`Info.plist`, regenerate an icon if wanted, then `./build.sh <Dir> "<Name>"`.
