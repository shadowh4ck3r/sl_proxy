# SL_Proxy

A modern iOS proxy client with a glassy gold and orange UI, rule-based routing, and a
[sing-box](https://github.com/SagerNet/sing-box) core supporting Shadowsocks, VMess, VLESS,
Trojan, SOCKS5, HTTP(S), Hysteria / Hysteria2, TUIC and WireGuard.

> **Status: Phase 3 (sideload-friendly tunnel + manual server editor).** The tunnel receives its
> configuration through the VPN profile and no longer needs the App Group entitlement, and servers
> can be typed in by hand (V2Box / Shadowrocket style) as well as imported from share links, QR
> codes, the clipboard and subscriptions. Next: Clash YAML / sing-box JSON subscriptions, per-app
> rules, widgets and on-demand connect.

> **This branch (`feature/user-space-loopback`) builds the user-space variant** for iOS 17.x
> installs where the packet tunnel extension cannot launch (TrollStore Lite, no CoreTrust bypass).
> sing-box runs inside the app and serves an HTTP + SOCKS5 proxy on `127.0.0.1:20080` (not 1080,
> which other proxy tools on the device usually hold and which fails with `bind: address already in
> use`); the port can be changed under **Settings > Local proxy**, with presets 20080, 20081, 20082,
> 20880, 21080, 28080 and 38080 that are also tried automatically when the chosen port is busy.
> There is no tunnel extension, VPN profile or special entitlement, and the bundle ID is
> `com.slproxy.userspace` so it installs next to the system VPN build. Other apps use it through
> Settings > Wi-Fi > Configure Proxy > Manual (`127.0.0.1`, port `20080` or the one shown on Home)
> or their own SOCKS5 option, and only while
> SL_Proxy stays in the foreground. CI publishes `SailorsLoot-UserSpace-Test.ipa` (ad-hoc signed for
> TrollStore / TrollStore Lite) and `SailorsLoot-UserSpace-Test-unsigned.ipa`. The system VPN build
> and `SL_ProxyTunnel/` live on `main` and are unchanged.

## Features

- **Import**: `ss://`, `vmess://`, `vless://`, `trojan://`, `socks://`, `http(s)://`,
  `hysteria://`, `hysteria2://` / `hy2://`, `tuic://`, `wireguard://` / `wg://`; paste, clipboard,
  QR scanner, opening a share link from another app, and subscription URLs (Base64 or plain lists)
- **Manual entry**: add or edit any server by hand with protocol-specific fields (SOCKS5 / HTTP
  login, Shadowsocks method and plugin, VMess / VLESS / Trojan transport, TLS and Reality,
  Hysteria / Hysteria2 obfuscation and bandwidth, TUIC, WireGuard keys); a share link is generated
  for every hand-entered server so it can be copied or exported
- **Home**: one-tap connect ring, active server card with latency, Global / Rule / Direct switch,
  live download/upload chart with totals and uptime
- **Configs**: grouped by subscription, tap to select, swipe to ping, edit or delete, test all
  latencies, copy share links, per-subscription refresh
- **Rules**: bypass LAN, bypass China (geosite/geoip rule sets), block ads, custom domain / keyword /
  exact / CIDR rules with proxy, direct or block actions
- **Logs**: live sing-box log stream from the extension with pause, copy and clear
- **Settings**: remote and local DNS with DoH presets, MTU, network stack, IPv6, strict route,
  sniffing, connect on launch, log level, generated config preview, diagnostics, credits
- A running tunnel restarts automatically when you switch server or change routing settings

## Layout

| Path | Purpose |
|------|---------|
| `project.yml` | XcodeGen spec (app + tunnel extension, iOS 16.0); both targets sign with the committed `.entitlements` below |
| `SL_Proxy/App` | App entry point and tab shell |
| `SL_Proxy/Core` | Node model, share-link parser and encoder, sing-box config builder, stores, traffic monitor |
| `SL_Proxy/Features` | Home, Configs (incl. manual editor), Rules, Logs, Settings screens |
| `SL_Proxy/Theme` | Brand palette, glass cards, shared components |
| `SL_Proxy/SL_Proxy.entitlements` | App entitlements: `packet-tunnel-provider` + App Group `group.sailorsloot.proxy` |
| `SL_ProxyTunnel/` | `NEPacketTunnelProvider` running Libbox, platform bridge, log buffer, matching `.entitlements` |
| `Shared/` | Code compiled into both targets (App Group discovery, provider configuration keys, IPC message types) |
| `Signing/` | Superset entitlements used to ad-hoc sign the TrollStore IPA (same App Group) |
| `Frameworks/` | `Libbox.xcframework` output (built, not committed) |
| `scripts/` | Libbox build, brand asset generation, App Group entitlements, CI signing bootstrap, IPA packaging |
| `.gitlab-ci.yml` | Pipeline on GitLab-hosted macOS runners producing the IPA |

## Requirements

- Xcode 16+, a physical iPhone on iOS 16.0+ (VPN tunnels do not run in the Simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Go 1.22+ (only to build Libbox locally)
- For **signed** builds: an Apple Developer account with the **Network Extensions** (Packet Tunnel)
  and **App Groups** capabilities enabled on both identifiers:
  - `com.slproxy.app`
  - `com.slproxy.app.tunnel`
  - App Group: `group.sailorsloot.proxy`
- For **TrollStore** builds: nothing. The pipeline ad-hoc signs the IPA with the same entitlements.

## App Group entitlements

iOS only lets the container app and the tunnel extension share a container when **both** code
signatures carry an identical `com.apple.security.application-groups` value. If one side lacks it,
the extension is killed at launch and the app reports *"The VPN session failed because an internal
error occurred"*.

`scripts/setup-app-group.sh` keeps everything in step. It writes four files:

| File | Used by |
|------|---------|
| `SL_Proxy/SL_Proxy.entitlements` | Xcode (`CODE_SIGN_ENTITLEMENTS` of the app target in `project.yml`) |
| `SL_ProxyTunnel/SL_ProxyTunnel.entitlements` | Xcode (`CODE_SIGN_ENTITLEMENTS` of the tunnel target) |
| `Signing/MainApp.entitlements` | `scripts/package-unsigned-ipa.sh` when ad-hoc signing the TrollStore app |
| `Signing/PacketTunnel.entitlements` | `scripts/package-unsigned-ipa.sh` when ad-hoc signing the TrollStore appex |

All four contain `packet-tunnel-provider` and the App Group `group.sailorsloot.proxy`; the script
also rewrites `AppGroup.defaultIdentifier` in `Shared/AppGroup.swift` and fails if `project.yml`
stops referencing the files. It runs in CI and via `make project`. To use another group:

```bash
APP_GROUP_ID=group.your.name make app-group    # or: APP_GROUP_ID=... bash scripts/setup-app-group.sh
bash scripts/setup-app-group.sh --check        # verify only
```

## Build locally

```bash
make libbox                                # builds Frameworks/Libbox.xcframework (one-off, slow)
APPLE_TEAM_ID=XXXXXXXXXX make project      # fetches brand assets, writes entitlements, generates SL_Proxy.xcodeproj
open SL_Proxy.xcodeproj                    # run on a device
```

`make build` compiles for the Simulator as a quick check; `make ipa` produces an unsigned IPA
in `build/ipa/`.

## Branding

`scripts/fetch-brand-assets.sh` downloads the artwork from sailorsloot.xyz and writes:

- `SL_Proxy/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`: opaque 1024x1024 app icon
  (transparent pixels are filled with `ICON_BACKGROUND`, default `0F1014`)
- `SL_Proxy/Assets.xcassets/Logo.imageset/logo.png`: in-app logo shown in the Home header

It runs automatically in CI and via `make project`. Override `APP_ICON_URL`, `IN_APP_LOGO_URL`,
`ICON_BACKGROUND` or `ICON_INSET` to tweak the result, or commit the generated PNGs to pin them.

## Testing on a device

1. Install the IPA (signed build, or sideload the unsigned one with AltStore / Sideloadly).
2. Configs tab: tap **+** and add a server manually, paste a share link, scan a QR code or add a
   subscription URL.
3. Home tab: tap the power ring. iOS asks once to allow the VPN configuration.
4. Watch the speed chart on Home and the core output in the Logs tab. If the tunnel stops right
   after connecting, the error from the core is shown on Home and in Logs.

### Sideloading (unsigned IPA)

Sideloadly, AltStore, ESign and similar tools re-sign the IPA with your own certificate. Along the
way they usually drop or rename the `group.sailorsloot.proxy` App Group, which is why builds before
0.3.0 failed with "The App Group container is unavailable". The app now hands the sing-box
configuration to the tunnel through the VPN profile (`NETunnelProviderProtocol.providerConfiguration`)
and the tunnel runs from its own sandbox when no shared container exists, so the App Group is
optional there. **Settings > Diagnostics** shows whether it was granted and which transport the
tunnel used; connecting works either way.

The **Network Extension** (`packet-tunnel-provider`) entitlement is still mandatory and cannot be
faked: free Apple IDs do not get it, so a build re-signed with a free account installs but the VPN
refuses to start. Use a paid developer team (Sideloadly / AltStore with a paid account keep the
entitlement), TrollStore, or a signing service that explicitly supports Network Extensions.

### TrollStore

The pipeline also produces **`SL_Proxy-trollstore.ipa`**: the same build, ad-hoc signed with
`Signing/MainApp.entitlements` and `Signing/PacketTunnel.entitlements` (Network Extension
`packet-tunnel-provider` + `app-proxy-provider`, `allow-vpn`, the `com.apple.managed.vpn.shared`
keychain group, explicit `application-identifier`, and the App Group `group.sailorsloot.proxy` in
**both** signatures so the app and the extension get one shared container). TrollStore keeps
whatever entitlements it finds in the existing signature, and the raw unsigned IPA has none, so
installing that one ends in `NEConfigurationErrorDomain Code=10 "permission denied"` when the app
tries to save the VPN profile. Always install the `-trollstore` IPA through TrollStore.

`package-unsigned-ipa.sh` refuses to produce the IPA if the app and the appex signatures disagree on
the App Group, which is the cause of *"The VPN session failed because an internal error occurred"*.

If it still fails:

1. Unzip the IPA and check both signatures carry the entitlements:
   `codesign -d --entitlements :- Payload/SL_Proxy.app` and
   `codesign -d --entitlements :- Payload/SL_Proxy.app/PlugIns/SL_ProxyTunnel.appex`.
   `packet-tunnel-provider` and `group.sailorsloot.proxy` must appear in both.
2. `application-identifier` of the appex must start with the same prefix as the app.
3. After replacing the app, use TrollStore's *Refresh App Registrations* (or uninstall first).
4. Watch `nehelper` / `neagent` in Console.app or `idevicesyslog` while tapping Connect; the denial
   line names the missing entitlement.

## CI pipeline

| Stage | Job | What it does |
|-------|-----|--------------|
| core | `build_libbox` | Clones the pinned sing-box tag (`SINGBOX_VERSION`) and builds `Libbox.xcframework` |
| verify | `build_simulator` | Fetches brand assets, writes the App Group entitlements, generates the project and compiles for the Simulator |
| package | `build_ipa` | Archives and exports the IPA as a job artifact |

`build_ipa` produces a **signed** IPA when the variables below exist, otherwise it falls back to
`SL_Proxy-unsigned.ipa`, which you can sideload with AltStore or Sideloadly using your own Apple ID,
and `SL_Proxy-trollstore.ipa` for TrollStore.

### Signing variables (Settings → CI/CD → Variables, masked)

| Variable | Value |
|----------|-------|
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_CERTIFICATE_P12` | `base64 -i cert.p12` of your distribution certificate |
| `APPLE_CERTIFICATE_PASSWORD` | password of the `.p12` |
| `APPLE_PROVISIONING_PROFILE_APP` | `base64 -i app.mobileprovision` for `com.slproxy.app` |
| `APPLE_PROVISIONING_PROFILE_TUNNEL` | `base64 -i tunnel.mobileprovision` for `com.slproxy.app.tunnel` |
| `APPLE_EXPORT_METHOD` (optional) | `release-testing` (default), `debugging`, `app-store-connect` |
| `APPLE_CODE_SIGN_IDENTITY` (optional) | `Apple Distribution` (default) or `Apple Development` |
| `APP_GROUP_ID` (optional) | App Group written into every entitlements file (default `group.sailorsloot.proxy`) |

Both provisioning profiles must include the Network Extension entitlement and the App Group named
in the entitlements files (Xcode rejects an entitlement the profile does not grant).

## Roadmap

1. ~~**Foundation**: scaffold, tunnel skeleton, theme, IPA pipeline~~
2. ~~**Core wiring**: start/stop sing-box via Libbox, config hand-off through the VPN profile, traffic stats~~
3. ~~**Config import**: share links for every protocol, QR scanning, clipboard, manual editor~~
4. **Subscriptions**: ~~Base64 lists, refresh, latency ping~~, Clash YAML, sing-box JSON, auto-update
5. **Routing and DNS**: ~~global / rule / direct modes, domain, IP and geo rules, DoH~~, per-app rules
6. **Polish**: on-demand connect, widgets, iCloud backup

---

A Sailorsloot Project © 2026 · @poshmipo (Senior Developer / Creator / Software manager) ·
@Toolsbrain/Toolsbrain13723 (Developer) · @cptkat (UI designer / Developer) ·
@ShadowH4ck3r (uicache / logs input / Proxy Address Engine Config Creator)
