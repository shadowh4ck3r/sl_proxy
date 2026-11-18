# Over-the-air UI and logic (OTA)

Push banners, cards, toggles, buttons, announcement modals and small pieces of logic to every
installed SL_Proxy straight from `https://sailorsloot.xyz/wp-admin`, without re-signing or
re-sideloading the IPA.

```
WordPress (SL_Proxy OTA page)  ->  GET /wp-json/slproxy/v1/ota  ->  OTAManager  ->  DynamicOTAView
        ui.json + logic.js                                         validate, cache      draws ui.json
                                                                   JavaScriptCore       taps -> logic.js
```

## Files

| File | Where it goes |
|---|---|
| `SL_Proxy/Core/OTAManager.swift` | fetch, validate, cache, JavaScriptCore bridge |
| `SL_Proxy/Features/OTA/DynamicOTAView.swift` | SwiftUI renderer and the announcement-modal sheet |
| `SL_Proxy/Resources/default_ui.json`, `default_logic.js` | starter bundle compiled into the IPA (offline fallback) |
| `backend/slproxy-ota.php` | single-file WordPress plugin |

## Install the plugin

1. Upload `slproxy-ota.php` to `wp-content/plugins/slproxy-ota/` (File Manager or the EasyWP
   dashboard), or zip it and use Plugins > Add New > Upload.
2. Activate it. A **SL_Proxy OTA** entry appears in the admin menu.
3. Open `https://sailorsloot.xyz/wp-json/slproxy/v1/ota?t=1` in a browser: you get JSON with the
   starter bundle. Edit the two text areas and press **Publish** to push your own.

The plugin sends `Cache-Control: no-store, no-cache, must-revalidate, max-age=0`, and the app adds
`?t=<milliseconds>` to every request, so EasyWP's cache never serves an old bundle.

## Wiring in the app (already done in this patch)

`ContentView.swift` creates the manager next to `nodes`, `settings` and `tunnel` and starts it:

```swift
@EnvironmentObject private var nodes: NodeStore
@EnvironmentObject private var settings: SettingsStore
@EnvironmentObject private var tunnel: TunnelController
@StateObject private var ota = OTAManager()          // OTAManager.Configuration.live

var body: some View {
    TabView(selection: $tab) { /* tabs */ }
        /* ...existing modifiers... */
        .onChange(of: settings.value) { _ in tunnel.applyChanges() }
        .otaModals(ota)                               // announcement modals
        .environmentObject(ota)                       // DynamicOTAView reads it
        .task { ota.start(nodes: nodes, settings: settings, tunnel: tunnel) }
}
```

`start` loads the cached (or bundled) bundle, checks the server once, and from then on checks again
every time the app becomes active (at most once per 20 s). Placements are filled by
`DynamicOTAView(placement:)`: `home.top` and `home.bottom` in `HomeView`, `settings.top` in
`SettingsView`. A placement with nothing to show draws nothing.

To use a backup endpoint or signatures, build the manager with a configuration:

```swift
@StateObject private var ota = OTAManager(configuration: .init(
    primaryURL: "https://sailorsloot.xyz/wp-json/slproxy/v1/ota",
    backupURL: "https://backup.example.com/ota.json",        // optional, nil or "" skips it
    publicKeyBase64: "<base64 public key>"))                 // optional, see Signing
```

The server may also send a `backup_url` (field on the OTA page). It is remembered and used from the
next check on.

## Offline fallback chain

1. **Remote**: fetched on launch and on `didBecomeActive`, primary first (5 s timeout), then the
   backup when the primary fails.
2. **Validate, then cache**: `ui.json` must decode, `logic.js` must load in a sandboxed `JSContext`
   without an exception, every function a `js` action names must exist, and the signature must match
   when a key is configured. Only then is it written to `Documents/OTA/` and `UserDefaults`.
   Failing validation, or an unreachable site, silently keeps the running version.
3. **Bundled**: with no cache (first offline launch) the starter bundle inside the IPA is used. If
   even that fails, nothing dynamic is drawn and the native screens are untouched.

## ui.json

```json
{
  "schema": 1,
  "flags": { "smartRouting": false, "hide_home_chart": true },
  "components": [
    { "id": "promo-1", "type": "banner", "placement": "home.top", "icon": "megaphone.fill",
      "title": "Weekend deal", "body": "20% off proxies.", "buttonTitle": "Open",
      "dismissible": true, "action": { "type": "url", "url": "https://sailorsloot.xyz" } }
  ]
}
```

Built-in flags the app reads from `flags`:

| Flag | Meaning |
|---|---|
| `hide_home_chart` | Bool, default `true`. The live traffic chart lives in Settings; set `false` to show it on Home again. |
| `default_home_layout` | String: `classic`, `tactical`, `telemetry` or `terminal`. Home layout used until the user picks one in Settings > Appearance > Home Screen Style. |
| `singbox_overrides` | Object (or a JSON string). Deep-merged onto the generated sing-box config right before it is written; objects merge key by key, arrays and scalars replace. `inbounds` and `experimental.clash_api` are ignored. A bundle without the key clears the previous override. |

Example: `"singbox_overrides": { "log": { "level": "error" }, "dns": { "strategy": "ipv4_only" } }`

| Field | Meaning |
|---|---|
| `type` | `banner` / `card` (same look), `button`, `toggle`, `modal`. Unknown types are ignored. |
| `placement` | `home.top` (default), `home.bottom`, `settings.top`. Modals ignore it. |
| `title`, `body`, `icon` (SF Symbol), `imageURL`, `buttonTitle` | content |
| `key` | toggles: name of the flag it reads and writes (defaults to `id`) |
| `action` | `{"type":"js","fn":"name","args":[...]}`, `{"type":"url","url":"https://..."}`, `{"type":"toast","message":"..."}`, `{"type":"dismiss"}`. A toggle passes its new value as the last argument. |
| `dismissible` | shows an X; dismissed ids stay hidden (change the `id` to show it again) |
| `showOnce` | modals: default true, shown once per `id` |
| `startsAt`, `expiresAt` | ISO 8601, e.g. `2026-12-01T00:00:00Z` |
| `minAppVersion`, `enabled` | hide for older apps / switch off without deleting |

## logic.js: what the app offers

| Function | Does |
|---|---|
| `setToast(message)` | `nodes.toast` |
| `applyProxyConfig(link)` | adds the server from a share link if it is new, selects it; a running tunnel switches by itself (`tunnel.applyChanges()` fires from the selection change). Returns `true` if the link was understood. |
| `setRoutingMode("rule" \| "global" \| "direct")` | `settings.value.routingMode` |
| `getAppState()` | `{appVersion, build, otaVersion, activeNodeID, activeNodeName, nodeCount, tunnelStatus, connected, port, routingMode, navigationStyle}` |
| `getFlag(key, fallback)`, `setFlag(key, bool)` | feature flags shared with native code |
| `setSingBoxOverrides(jsonString)` | stores the sing-box config override (same as `flags.singbox_overrides`); `""` or `"{}"` clears it. Returns `false` when the text is not a JSON object. A running tunnel switches by itself. |
| `openURL(url)` | http(s) only |
| `console.log(text)` | device log |

If `logic.js` defines `onLoad()`, it runs once after a bundle becomes active.

Native code can use the same bundle:

```swift
if ota.flag("smartRouting") { ... }                       // flag, falls back to ui.json "flags"
let price = await ota.call("computePrice", args: [9.99, "yearly"])   // runs in the sandbox, 3 s limit
```

The sandbox has no network, file or timer access. A script that never returns blocks only its own
queue: the call times out after 3 s, the runtime is replaced, the UI never freezes.

## Signing (recommended)

`applyProxyConfig` lets the bundle change the server of every phone, so a stolen WordPress login
would otherwise be enough to redirect all your users' traffic. Sign the bundles instead:

```sh
php -r '$k = sodium_crypto_sign_keypair();
echo "secret: ", base64_encode(sodium_crypto_sign_secretkey($k)), "\n";
echo "public: ", base64_encode(sodium_crypto_sign_publickey($k)), "\n";'
```

* Put the **secret** in `wp-config.php` (never in the database or the admin page):
  `define( 'SLPROXY_OTA_SIGNING_KEY', '<secret>' );` The OTA page then shows "Signing: On".
* Put the **public** key in the app: `publicKeyBase64:` in the `OTAManager` configuration. From then
  on the app rejects any bundle without a valid signature, including one served by a hacked site.

Signature = Ed25519 over `slproxy-ota-v1\n<version>\n<sha256(ui.json)>\n<sha256(logic.js)>`.

## Notes

* Loading server-supplied JavaScript that changes app behaviour is fine for sideloaded and
  TrollStore builds, but App Store review guideline 2.5.2 does not allow it.
* The plugin refuses to publish invalid JSON, duplicate ids, a `schema` newer than the apps know, or
  a non-https `backup_url`; it warns when a `js` action names a function it cannot find in
  `logic.js` (the app does the authoritative check and keeps the old bundle if it is missing).
* **Revert to previous bundle** restores the bundle published before the current one.
