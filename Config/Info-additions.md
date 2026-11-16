# Project settings this feature needs

## Info.plist
- Do NOT add any `NSAppTransportSecurity` exception. All account calls are HTTPS to sailorsloot.xyz.
- Launch screen colour so the in-app splash blends in (optional):
  `UILaunchScreen` > `UIColorName` = a black/dark color set.
- iCloud Drive folder visible in Files (optional):
  `NSUbiquitousContainers` > `<container id>` > `NSUbiquitousContainerIsDocumentScopePublic` = YES,
  `NSUbiquitousContainerName` = SL_Proxy, `NSUbiquitousContainerSupportedFolderLevels` = Any.

## Entitlements (SL_Proxy.entitlements)
- `com.apple.developer.icloud-container-identifiers` = `iCloud.<your bundle id>`
- `com.apple.developer.icloud-services` = `CloudDocuments`
- `com.apple.developer.ubiquity-container-identifiers` = `iCloud.<your bundle id>`
iCloud needs a signed build with the iCloud capability. TrollStore / sideloaded copies that are
re-signed without it will show "iCloud is not available" in the backup screen; nothing else breaks.
