# SL_Proxy x sailorsloot.xyz: batch 2 integration notes

Nothing was committed or pushed. The zip you sent is a partial project (15 files, no Xcode project,
no ProxyNode / TunnelController / ContentView / Settings root), and I had no compiler here, so
**nothing has been built or run**. Expect a few compile fixes on first build.

## 1. WordPress (do this first)
1. Install `backend/sl-proxy-api.php` (plugin, or Code Snippets without the `<?php` and header).
2. Keep your existing snippets active: the purchase flow calls `sailorsloot_build_9proxy_username`,
   `sailorsloot_verify_9proxy_connection`, `sailorsloot_get_custom_attribute`. If any is missing the
   purchase **fails closed** (no charge, no credentials).
3. Hooks to edit if you want different behaviour: `sl_proxy_hook_get_balance`, `sl_proxy_hook_debit`,
   `sl_proxy_hook_credit`, `sl_proxy_hook_allocate_and_verify` (all marked PLUG IN HERE; each also has a filter).
4. If logins return 401 on every call, your host strips the Authorization header. Add to .htaccess:
   `RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]` (the app header `X-SL-Authorization` is also accepted).
5. Test:
   `curl -s https://sailorsloot.xyz/wp-json/sl-proxy/v1/auth/login -d 'login=USER&password=PASS'`
   then `curl -s -H "Authorization: Bearer TOKEN" https://sailorsloot.xyz/wp-json/sl-proxy/v1/proxies`.

Behaviour to know:
- The IP you buy comes from the product's `_sl_proxy_country/_state/_city/_isp` attributes (your existing
  engine), not from the exact masked IP shown in the list. The purchase reply returns the resolved IP/city.
- Re-buying a listing you still hold returns the same credentials, no second charge.
- Rotate the 9Proxy password and relay secret you pasted in chat; keep them in wp-config.php.

## 2. Files in this zip
New (iOS): Core/KeychainManager, SLAPIClient, SLModels, AccountStore, MarketStore, ProxyConnector,
SOCKS5Probe, SLCloudSync; Features/Account/ConnectAccountView; Features/Market/MarketView, PurchaseSheet,
FilterSheet; Features/Home/DraggableConnectButton; Features/Settings/CloudBackupView, AboutSection;
Features/SplashGate; Theme/GuideText.
Modified: NodeStore (accurate ping, expiries, upsertPurchased), HomeView (draggable button, market card),
CellularCard, LocalProxyCard, ShareConfigSheet, AppearanceSettingsView (smaller guides, dock reset).
Other: scripts/fetch-splash.sh (+ call in fetch-brand-assets.sh), Config/SL_Proxy-Release.xcconfig, Config/Info-additions.md.

## 3. Edits you must make in files that were not in the zip
- **App root** (`SLProxyApp`): `SplashGate { ContentView() ... }` around the root view, and once at launch
  `SLCloudSync.shared.attach(to: nodes)`.
- **Settings list**: add `AccountSettingsRow()` near the top, a row `NavigationLink("iCloud Backup") { CloudBackupView() }`
  (replace the old backup row/screen), and `SettingsAboutStack()` at the bottom (replaces the Telegram row).
- **Other settings screens** (Carrier Profile, Tunnel Settings, ...): change section footers/descriptions to
  `Text("...").guideFooter()` and inline hints to `.guideText()`. To remove all guide text instead set
  `GuideTextStyle.hideAll = true`.
- **Tabs (optional)**: Home already has a Proxy Market card. For a tab, add `MarketView()` in ContentView.
- **Xcode**: apply `Config/SL_Proxy-Release.xcconfig`; iCloud entitlements per `Config/Info-additions.md`;
  run `scripts/fetch-brand-assets.sh` (needs network) to create the Splash asset.

## 4. Assumptions to verify at first build
- `ProxyURLParser.parseMany("socks5://user:pass@host:port#name")` yields a `.socks` node (falls back to `socks://`). `ProxyNode.name` is `var`.
- `ProxyNode` is `Codable`, with `server`, `port` (Int), `username`, `password` (optional strings).
- `TunnelController.toggle()` reads the selected node; `ProxyConnector` stops then starts when switching servers.
- `ConnectionButtonSize.diameter` exists (used by HomeView already).

## 5. Why Washington showed ms while dead
The old test was a bare TCP connect to the gateway, which succeeds even for an expired session.
`ProxyProbe` now does the SOCKS5 login, opens a tunnel and requires an HTTP answer; anything less is
"timeout". Configs bought in the app also store their expiry and read timeout after it passes.
The active server while connected still uses the existing real-delay test.

## 6. Security notes
- Token only in Keychain (this-device-only); 401 clears it and opens the sign-in screen. HTTPS-only client,
  redirects off sailorsloot.xyz refused, no pinning, no cache or cookies.
- Purchased credentials are saved in Configs (nodes.json in the app group) as every config is today.
  That file is not encrypted by this change.
- Release stripping hides symbols, not strings: the API URL is visible in the binary, which is fine
  because no secret ships in the app.
