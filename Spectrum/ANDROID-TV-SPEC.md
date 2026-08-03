# Spectrum TV Android TV App — Build Specification

## Target Device

| Property | Value |
|----------|-------|
| Device | Chromecast with Google TV (4K) — codename "sabrina" |
| SoC | Amlogic S905X2 |
| CPU ABI | **armeabi-v7a, armeabi** (32-bit ONLY — no arm64) |
| Android | 14 (API 34) |
| RAM | 2 GB |
| Storage | ~4.5 GB usable |
| Display | 1920x1080, tvdpi |
| Input | D-pad remote (no touchscreen) |

**CRITICAL: The app MUST compile for 32-bit ARM (armeabi-v7a). The device cannot run arm64 native code.**

---

## The Problem

Spectrum TV launched an Android TV app (`com.spectrum.stva.androidtv`) in April 2026, but it is **64-bit only**. The Chromecast with Google TV (4K) runs a 32-bit OS and cannot execute 64-bit native code. There is no workaround — the official app will never run on this device.

## The Solution

Build a **WebView-based Android TV app** that wraps Spectrum's web streaming interface (`watch.spectrum.net`). This approach:
- Requires no DRM reverse engineering (the web browser handles Widevine)
- Works on 32-bit devices (WebView is provided by the OS)
- Is maintainable (Spectrum updates their web app, not us)
- Has existing open-source references (see below)

---

## Existing Open-Source References

### 1. IsaacSchemm/SpectrumTV_webview
- **GitHub:** https://github.com/IsaacSchemm/SpectrumTV_webview
- **Approach:** Simple WebView that loads `watch.spectrum.net`
- **Features:**
  - Channel switching via D-pad (channel up/down, number input)
  - MiniGuide scanning and persistence
  - ADB intent support for channel number input
  - 4-hour session timeout with "Continue" prompt
  - Away-from-home login support
- **Package:** `com.spectv`
- **Min SDK:** 25 (Android 7.1)
- **Architecture:** Java, single Activity with WebView
- **Key techniques:**
  - JavaScript manipulation to hide unnecessary HTML elements
  - `WebViewClient` overrides for handling Spectrum's auth flow
  - `SharedPreferences` for channel guide persistence
  - Intent filter for deep linking: `spectv://watch.spectrum.net/livetv?channelNum=[chnum]`

### 2. theWinterDojer/SpecStream
- **GitHub:** https://github.com/theWinterDojer/SpecStream
- **Approach:** Dual WebView architecture with overlay channel guide
- **Features:**
  - Full channel guide overlay (not just mini-guide)
  - D-pad optimized navigation
  - Auto-authentication on home network
  - Manual login when away from home
  - Channel memory (remembers last channel)
  - Hardware-accelerated video playback
- **Package:** `com.specstream`
- **Min SDK:** 26 (Android 8.0)
- **Target SDK:** 36
- **Language:** Kotlin
- **Architecture:** Dual WebView with JavaScript bridge
- **Key techniques:**
  - JavaScript bridge for communication between native Android and web content
  - Overlay UI for channel guide on top of WebView
  - Leanback launcher integration
  - D-pad key event interception and remapping

---

## Recommended Architecture

### Option A: Enhanced WebView Wrapper (Recommended)

Based on SpecStream's architecture but simplified for the 32-bit target.

```
┌─────────────────────────────────────────────┐
│                 MainActivity                │
│  ┌─────────────────────────────────────────┐│
│  │           ChannelGuideFragment          ││
│  │  (Overlay UI - D-pad navigable)         ││
│  └─────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────┐│
│  │           Video WebView                 ││
│  │  (loads watch.spectrum.net)             ││
│  │  ┌───────────────────────────────────┐  ││
│  │  │    JavaScript Bridge              │  ││
│  │  │    (channel control, auth, etc.)  │  ││
│  │  └───────────────────────────────────┘  ││
│  └─────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────┐│
│  │           MiniPlayer Overlay            ││
│  │  (current channel + program info)       ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

### Option B: Full Native + WebView Hybrid

Build native Android TV UI components (channel guide, search, settings) using Jetpack Compose for TV, with WebView only for video playback. More work but better UX.

---

## Feature Requirements

### P0 — Must Have
1. **Authentication Flow**
   - Auto-detect home network (Spectrum IP range) for silent auth
   - Manual username/password login when away from home
   - Handle session expiry and re-auth
   - Persist login tokens in `EncryptedSharedPreferences`

2. **Live TV Playback**
   - Load `watch.spectrum.net/livetv` in WebView
   - Ensure hardware acceleration is enabled for video
   - Handle WebView video autoplay permissions
   - Support picture-in-picture (if possible on this device)

3. **Channel Navigation**
   - D-pad up/down: open/close channel guide
   - D-pad left/right: navigate within guide
   - D-pad center: select channel
   - Channel number input: numeric keypad overlay
   - Channel up/down buttons on remote
   - Last channel toggle (double-press back or dedicated button)

4. **Channel Guide**
   - Parse mini-guide from Spectrum's web interface
   - Display as native Android TV overlay (not web-rendered)
   - Show current + next program for each channel
   - Scrollable with D-pad
   - Persist channel data locally for fast loading

5. **32-bit Compatibility**
   - `minSdk = 26` (Android 8.0)
   - `targetSdk = 34` (Android 14)
   - All native libraries must be armeabi-v7a or pure Java/Kotlin
   - No arm64-only dependencies
   - Test on actual device or 32-bit emulator

### P1 — Should Have
6. **Search**
   - Search by show name, network, actor
   - Use Spectrum's web search or build native search UI

7. **On Demand**
   - Browse On Demand catalog
   - Play On Demand content through WebView

8. **Parental Controls**
   - PIN protection
   - Content rating filters

9. **Favorites**
   - Mark favorite channels
   - Quick access list

10. **Channel Memory**
    - Remember last watched channel on app restart
    - Resume playback from last position

### P2 — Nice to Have
11. **DVR Integration** (if user has DVR service)
    - View DVR recordings
    - Schedule recordings
    - Play DVR content

12. **Multiview**
    - Watch multiple channels simultaneously

13. **Voice Search**
    - Google Assistant integration
    - "Play [channel name]" voice commands

---

## Technical Specifications

### Build Configuration

```kotlin
// build.gradle.kts
android {
    compileSdk = 34
    
    defaultConfig {
        applicationId = "com.spectv.tv" // or custom package name
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
        
        // CRITICAL: 32-bit only
        ndk {
            abiFilters += listOf("armeabi-v7a", "armeabi")
        }
    }
    
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    
    kotlinOptions {
        jvmTarget = "1.8"
    }
}
```

### Dependencies

```kotlin
dependencies {
    // Android TV / Leanback (for launcher icon, banner)
    implementation("androidx.leanback:leanback:1.0.0")
    
    // WebView
    implementation("androidx.webkit:webkit:1.8.0")
    
    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    
    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.2")
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    
    // NO arm64-only libraries allowed
    // NO Firebase (adds native code)
    // NO Crashlytics (adds native code)
    // NO AdMob (adds native code)
}
```

### AndroidManifest.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    
    <!-- TV app requirement -->
    <uses-feature android:name="android.software.leanback" android:required="true" />
    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
    
    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:banner="@drawable/tv_banner"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.TvApp"
        android:usesCleartextTraffic="true"
        android:hardwareAccelerated="true">
        
        <activity
            .name=".MainActivity"
            android:exported="true"
            android:configChanges="orientation|screenSize|keyboardHidden"
            android:screenOrientation="landscape">
            
            <!-- Leanback launcher intent filter -->
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
            </intent-filter>
            
            <!-- Standard launcher (optional) -->
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
            
            <!-- Deep link support -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="spectv" 
                      android:host="watch.spectrum.net" 
                      android:pathPrefix="/livetv" />
            </intent-filter>
            
            <!-- Channel number intent -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:scheme="spectv"
                      android:host="channel" />
            </intent-filter>
            
        </activity>
        
    </application>
</manifest>
```

### Core Components

#### 1. MainActivity.kt

```kotlin
class MainActivity : FragmentActivity() {
    
    private lateinit var webView: WebView
    private lateinit var channelGuideOverlay: ChannelGuideOverlay
    private lateinit var miniPlayer: MiniPlayerOverlay
    private lateinit var authManager: AuthManager
    private lateinit var channelManager: ChannelManager
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        
        setupWebView()
        setupChannelGuide()
        setupKeyHandlers()
        
        // Handle intent (deep link / channel number)
        handleIntent(intent)
    }
    
    private fun setupWebView() {
        webView = findViewById(R.id.webview)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = false
            displayZoomControls = false
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        
        webView.webViewClient = SpectrumWebViewClient(authManager)
        webView.webChromeClient = SpectrumChromeClient()
        
        // Enable hardware acceleration
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        
        // Load Spectrum TV
        webView.loadUrl("https://watch.spectrum.net")
    }
    
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> {
                channelGuideOverlay.toggle()
                true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                // Channel down or guide navigation
                if (channelGuideOverlay.isVisible) {
                    channelGuideOverlay.moveDown()
                } else {
                    channelManager.channelDown()
                }
                true
            }
            // ... handle all D-pad keys
            else -> super.onKeyDown(keyCode, event)
        }
    }
}
```

#### 2. AuthManager.kt

```kotlin
class AuthManager(private val context: Context) {
    
    private val prefs = EncryptedSharedPreferences.create(
        "spectrum_auth",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    
    suspend fun attemptSilentAuth(): Boolean {
        // Check if we're on Spectrum home network
        // by testing connectivity to internal auth endpoints
        return try {
            val response = URL("https://api.spectrum.net/auth/check").openStream()
            // Parse response, save tokens
            true
        } catch (e: Exception) {
            false
        }
    }
    
    fun saveCredentials(username: String, password: String) {
        prefs.edit()
            .putString("username", username)
            .putString("password", password)
            .apply()
    }
    
    fun getCredentials(): Pair<String?, String?> {
        return Pair(
            prefs.getString("username", null),
            prefs.getString("password", null)
        )
    }
    
    fun injectAuthIntoWebView(webView: WebView) {
        // Inject cookies or JavaScript to authenticate
        val cookies = CookieManager.getInstance()
        // Set auth cookies...
    }
}
```

#### 3. ChannelManager.kt

```kotlin
class ChannelManager(private val context: Context) {
    
    data class Channel(
        val number: String,
        val name: String,
        val_callsign: String,
        val currentShow: String?,
        val nextShow: String?,
        val logoUrl: String?
    )
    
    private val channels = mutableListOf<Channel>()
    private var currentIndex = 0
    
    suspend fun scanMiniGuide(webView: WebView) {
        // JavaScript to extract channel data from Spectrum's mini-guide
        val js = """
            (function() {
                var channels = [];
                var guide = document.querySelector('.mini-guide');
                if (guide) {
                    var items = guide.querySelectorAll('.channel-item');
                    items.forEach(function(item) {
                        channels.push({
                            number: item.querySelector('.channel-number')?.textContent,
                            name: item.querySelector('.channel-name')?.textContent,
                            callsign: item.getAttribute('data-callsign'),
                            current: item.querySelector('.current-show')?.textContent,
                            next: item.querySelector('.next-show')?.textContent
                        });
                    });
                }
                return JSON.stringify(channels);
            })();
        """
        
        webView.evaluateJavascript(js) { result ->
            // Parse JSON and store channels
            val json = result?.removeSurrounding("\"")
            if (json != null) {
                parseChannelData(json)
            }
        }
    }
    
    fun channelUp() {
        currentIndex = (currentIndex + 1) % channels.size
        switchToChannel(channels[currentIndex])
    }
    
    fun channelDown() {
        currentIndex = (currentIndex - 1 + channels.size) % channels.size
        switchToChannel(channels[currentIndex])
    }
    
    fun switchToChannel(channel: Channel) {
        // Use JavaScript to change channel in WebView
        // Or use deep link: spectv://watch.spectrum.net/livetv?channelNum=XXX
    }
    
    fun switchToChannelNumber(number: String) {
        val channel = channels.find { it.number == number }
        if (channel != null) {
            switchToChannel(channel)
        }
    }
    
    fun saveToDisk() {
        // Persist channel list to SharedPreferences or file
    }
    
    fun loadFromDisk() {
        // Load previously scanned channel list
    }
}
```

#### 4. ChannelGuideOverlay.kt

```kotlin
class ChannelGuideOverlay(private val activity: FragmentActivity) {
    
    private val guideView: View = activity.findViewById(R.id.channel_guide_overlay)
    private val recyclerView: RecyclerView = activity.findViewById(R.id.guide_list)
    private var isVisible = false
    
    fun toggle() {
        if (isVisible) hide() else show()
    }
    
    fun show() {
        isVisible = true
        guideView.visibility = View.VISIBLE
        guideView.alpha = 0f
        guideView.animate().alpha(0.95f).setDuration(200).start()
        recyclerView.requestFocus()
    }
    
    fun hide() {
        isVisible = false
        guideView.animate().alpha(0f).setDuration(200).withEndAction {
            guideView.visibility = View.GONE
        }
    }
    
    fun moveUp() {
        val layoutManager = recyclerView.layoutManager as LinearLayoutManager
        val pos = layoutManager.findFirstVisibleItemPosition() - 1
        if (pos >= 0) {
            recyclerView.smoothScrollToPosition(pos)
        }
    }
    
    fun moveDown() {
        val layoutManager = recyclerView.layoutManager as LinearLayoutManager
        val pos = layoutManager.findLastVisibleItemPosition() + 1
        if (pos < (recyclerView.adapter?.itemCount ?: 0)) {
            recyclerView.smoothScrollToPosition(pos)
        }
    }
    
    fun selectCurrent() {
        // Get focused item and switch to that channel
    }
}
```

---

## Key Technical Challenges

### 1. JavaScript Bridge

Spectrum's web app communicates via JavaScript. You need to:

```kotlin
// Inject JavaScript to control the web app
webView.addJavascriptInterface(AndroidBridge(), "AndroidBridge")

class AndroidBridge {
    @JavascriptInterface
    fun onChannelChange(channelNumber: String) {
        // Called from web app when channel changes
    }
    
    @JavascriptInterface  
    fun onAuthRequired() {
        // Called when login is needed
    }
}

// Web app calls AndroidBridge from JavaScript:
// window.AndroidBridge.onChannelChange("55");
```

### 2. D-pad Key Mapping

The web app expects different key events than what Android TV sends:

```kotlin
// Map TV remote keys to web app expectations
fun mapKeyForWebView(keyCode: Int): Int {
    return when (keyCode) {
        KeyEvent.KEYCODE_DPAD_UP -> KeyEvent.KEYCODE_DPAD_UP
        KeyEvent.KEYCODE_DPAD_DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
        KeyEvent.KEYCODE_DPAD_CENTER -> KeyEvent.KEYCODE_ENTER
        KeyEvent.KEYCODE_CHANNEL_UP -> KeyEvent.KEYCODE_MEDIA_NEXT
        KeyEvent.KEYCODE_CHANNEL_DOWN -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
        else -> keyCode
    }
}
```

### 3. Video Playback Optimization

```kotlin
// Ensure smooth video playback
webView.settings.apply {
    // Hardware acceleration
    setLayerType(View.LAYER_TYPE_HARDWARE, null)
    
    // Disable unnecessary features
    javaScriptEnabled = true
    domStorageEnabled = true
    mediaPlaybackRequiresUserGesture = false
    
    // Cache for offline/quick reload
    cacheMode = WebSettings.LOAD_DEFAULT
}

// Keep screen on during playback
window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
```

### 4. Session Management

```kotlin
// Handle 4-hour timeout (Spectrum's limit)
class SessionManager {
    private val SESSION_TIMEOUT = 4 * 60 * 60 * 1000L // 4 hours
    private var lastActivity = System.currentTimeMillis()
    
    fun checkSession(): Boolean {
        val elapsed = System.currentTimeMillis() - lastActivity
        if (elapsed > SESSION_TIMEOUT) {
            showContinueDialog()
            return false
        }
        return true
    }
    
    fun showContinueDialog() {
        // Show "Continue watching?" dialog
        // On confirm: refresh session
        // On cancel: exit app
    }
}
```

---

## Testing Checklist

### Device Compatibility
- [ ] App installs via `adb install` on 32-bit device
- [ ] App launches without crash
- [ ] WebView loads `watch.spectrum.net`
- [ ] Video plays without stuttering
- [ ] D-pad navigation works throughout app
- [ ] Channel up/down works
- [ ] Channel number input works
- [ ] Channel guide overlay displays correctly
- [ ] Back button behavior is correct (guide → home → exit)
- [ ] App handles screen off/on correctly
- [ ] App handles network loss gracefully

### Authentication
- [ ] Auto-auth works on Spectrum home network
- [ ] Manual login works off-network
- [ ] Session persistence across app restarts
- [ ] Token refresh works
- [ ] Logout works

### Performance
- [ ] App starts in < 3 seconds
- [ ] Channel switch in < 2 seconds
- [ ] Guide scrolls smoothly (60fps)
- [ ] No memory leaks after 4+ hours
- [ ] WebView doesn't leak memory

### Edge Cases
- [ ] App works after device sleep/wake
- [ ] App handles multiple rapid key presses
- [ ] App handles network switching (WiFi → cellular)
- [ ] App survives WebView crashes
- [ ] App handles Spectrum server errors

---

## Build & Deploy

### Build
```bash
# Debug build
./gradlew assembleDebug

# Release build (unsigned)
./gradlew assembleRelease
```

### Deploy via ADB
```bash
# Install
adb install -r app/build/outputs/apk/debug/app-debug.apk

# Launch
adb shell am start -n com.spectv.tv/.MainActivity

# Launch with channel
adb shell am start -n com.spectv.tv/.MainActivity --es channelNum "55"

# View logs
adb logcat -s SpectrumTV:V
```

---

## File Structure

```
spectrum-tv/
├── app/
│   ├── src/
│   │   └── main/
│   │       ├── java/com/spectv/tv/
│   │       │   ├── MainActivity.kt
│   │       │   ├── AuthManager.kt
│   │       │   ├── ChannelManager.kt
│   │       │   ├── ChannelGuideOverlay.kt
│   │       │   ├── MiniPlayerOverlay.kt
│   │       │   ├── SessionManager.kt
│   │       │   ├── SpectrumWebViewClient.kt
│   │       │   ├── SpectrumChromeClient.kt
│   │       │   ├── KeyInterceptor.kt
│   │       │   └── AndroidBridge.kt
│   │       ├── res/
│   │       │   ├── layout/
│   │       │   │   ├── activity_main.xml
│   │       │   │   ├── channel_guide.xml
│   │       │   │   ├── channel_guide_item.xml
│   │       │   │   └── mini_player.xml
│   │       │   ├── values/
│   │       │   │   ├── strings.xml
│   │       │   │   ├── colors.xml
│   │       │   │   └── styles.xml
│   │       │   ├── drawable/
│   │       │   │   └── tv_banner.png
│   │       │   └── mipmap/
│   │       │       └── ic_launcher.png
│   │       └── AndroidManifest.xml
│   └── build.gradle.kts
├── gradle/
├── build.gradle.kts
├── settings.gradle.kts
└── gradle.properties
```

---

## Notes for Implementation

1. **Start simple** — Get the WebView loading Spectrum TV first, then add features incrementally
2. **Test on real hardware** — The 32-bit constraint is critical; emulators may not catch all issues
3. **Monitor memory** — WebView on limited RAM devices can be problematic; profile carefully
4. **Watch for Spectrum changes** — They may change their web interface; the JavaScript selectors may break
5. **Consider obfuscation** — Spectrum may detect and block unauthorized WebView clients; be prepared to update user-agent strings, headers, etc.
6. **The SpecStream project is the best starting point** — It already handles most of the hard problems (D-pad, channel guide, auth flow)

---

*Document generated for handoff to implementation agent.*
*Last updated: July 2026*
