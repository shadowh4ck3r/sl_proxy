# Release build hardening (recommendations)

Not applied to `project.yml` automatically: the CI IPA packaging scripts re-sign the binary, so try
each change on a branch build first.

Release configuration (XcodeGen `configs` / `settings.configs.Release`):

| Setting | Value | Why |
|---|---|---|
| `SWIFT_COMPILATION_MODE` | `wholemodule` | Better optimisation, fewer exposed symbols |
| `SWIFT_OPTIMIZATION_LEVEL` | `-O` (or `-Osize`) | No debug-only code paths |
| `GCC_GENERATE_DEBUGGING_SYMBOLS` | `NO` | No DWARF in the shipped binary |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` (not `dwarf-with-dsym`) | Skip dSYM for the ad-hoc IPA; keep it for signed builds you symbolicate |
| `COPY_PHASE_STRIP` | `YES` | Strip during copy |
| `STRIP_INSTALLED_PRODUCT` | `YES` | Strip the app executable |
| `STRIP_SWIFT_SYMBOLS` | `YES` | Strip Swift symbols from the app and linked Swift libraries |
| `STRIP_STYLE` | `all` | Removes local and debug symbols |
| `DEPLOYMENT_POSTPROCESSING` | `YES` | Required for the strip settings to run on `xcodebuild archive` |
| `ENABLE_TESTABILITY` | `NO` | Keeps internal symbols out |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | no `DEBUG` | Release logging off |

Also:
- Never log the Bearer token, passwords or proxy credentials (check `os_log` / `print` calls).
- Keep `NSAppTransportSecurity` default (no `NSAllowsArbitraryLoads`): all SailorsLoot calls are HTTPS.
- Do not add certificate pinning (WordPress renews the certificate); standard TLS validation applies.
- Rotate server secrets that were pasted anywhere public (9Proxy sub-user password, relay secret)
  and keep them in `wp-config.php`, never in the app.
