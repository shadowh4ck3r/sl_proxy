#!/usr/bin/env bash
# Generates one unsigned iOS configuration profile per carrier. Each profile carries a single
# com.apple.cellular payload whose APN entry points cellular data at the in-app SL_Proxy listener on
# 127.0.0.1:20080 (the user-space engine's default HTTP + SOCKS5 mixed inbound):
#
#   Airtel-Cellular-Proxy.mobileconfig    APN internet.ng.airtel.com   login internet / internet
#   MTN-Cellular-Proxy.mobileconfig       APN web.gprs.mtnn.net        no login
#   Glo-Cellular-Proxy.mobileconfig       APN gloflat                  no login
#   9mobile-Cellular-Proxy.mobileconfig   APN 9mobile                  no login
#
# It also writes one unified bundle that carries every carrier's APN in a single cellular payload,
# so a tester installs one profile regardless of which Nigerian SIM they use:
#
#   Universal-Cellular-Proxy.mobileconfig all four APNs in one com.apple.cellular payload
#
# A device keeps one cellular payload at a time, and iOS activates the APN entry that matches the
# inserted SIM, so the universal profile replaces the need to pick the right single-carrier file.
#
# The APN credentials are the ones each carrier publishes for manual configuration. Airtel Nigeria
# refuses the data context when the entry carries no username/password (the phone then has no
# internet at all and nothing reaches the listener); MTN, Glo and 9mobile accept a blank login, so
# their entries stay as they were.
#
# The Global HTTP Proxy payload (com.apple.proxy.http.global) is never emitted: iOS installs it on
# supervised devices only and these profiles must install on standard, unsupervised devices.
# INCLUDE_GLOBAL_HTTP_PROXY is pinned to 0 for every build; setting it in the environment only
# produces a warning.
#
# build_ipa runs this on feature/advanced-plus-ui only and writes the profiles into build/ipa so they
# ship in the same artifact archive as the IPAs. iOS keeps one cellular payload per device, so a
# tester installs either the Universal profile (recommended, covers every SIM) or the single file
# that matches their SIM, and removes it to return to the carrier's own settings.
#
# Usage: generate-cellular-mobileconfig.sh [output-dir]        (default build/ipa)
#
# Environment overrides (all optional):
#   PROXY_HOST                 proxy address written into every APN entry       (default 127.0.0.1)
#   PROXY_PORT                 proxy port                                       (default 20080)
#   CELLULAR_APN_USERNAME      APN user name for EVERY carrier; replaces the per-carrier default
#   CELLULAR_APN_PASSWORD      APN password for EVERY carrier; replaces the per-carrier default
#   CELLULAR_APN_AUTH_TYPE     PAP or CHAP, omitted when empty (device default applies)
#   PROFILE_IDENTIFIER         reverse-DNS prefix; the carrier slug is appended per profile
#                              (default com.slproxy.userspace.cellular-routing)
#   PROFILE_ORGANIZATION       shown in Settings > VPN & Device Management      (default Sailorsloot)
#   INCLUDE_GLOBAL_HTTP_PROXY  ignored; pinned to 0 (see above)
set -euo pipefail

OUT_DIR="${1:-build/ipa}"
# Older callers passed a single file path; keep them working by using its directory.
case "$OUT_DIR" in
  *.mobileconfig)
    echo "warning: '$OUT_DIR' looks like a file; one profile per carrier is written into its directory instead" >&2
    OUT_DIR="$(dirname "$OUT_DIR")"
    ;;
esac

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-20080}"
CELLULAR_APN_USERNAME="${CELLULAR_APN_USERNAME:-}"
CELLULAR_APN_PASSWORD="${CELLULAR_APN_PASSWORD:-}"
CELLULAR_APN_AUTH_TYPE="${CELLULAR_APN_AUTH_TYPE:-}"
PROFILE_ID="${PROFILE_IDENTIFIER:-com.slproxy.userspace.cellular-routing}"
ORG="${PROFILE_ORGANIZATION:-Sailorsloot}"

# Pinned across all builds: the profiles must install on unsupervised devices, so the
# supervision-only Global HTTP Proxy payload is never generated.
if [ "${INCLUDE_GLOBAL_HTTP_PROXY:-0}" != "0" ]; then
  echo "warning: INCLUDE_GLOBAL_HTTP_PROXY=${INCLUDE_GLOBAL_HTTP_PROXY:-} ignored; the Global HTTP Proxy payload is never generated" >&2
fi
INCLUDE_GLOBAL_HTTP_PROXY=0

# slug|file name|display name|APN|APN user name|APN password
# Empty user name / password mean the entry is written without credentials. Keep the Airtel login in
# step with Carrier.apnUsername / apnPassword in SL_Proxy/Core/Carrier.swift.
CARRIERS=(
  "airtel|Airtel-Cellular-Proxy.mobileconfig|Airtel|internet.ng.airtel.com|internet|internet"
  "mtn|MTN-Cellular-Proxy.mobileconfig|MTN|web.gprs.mtnn.net||"
  "glo|Glo-Cellular-Proxy.mobileconfig|Glo|gloflat||"
  "9mobile|9mobile-Cellular-Proxy.mobileconfig|9mobile|9mobile||"
)

case "$PROXY_PORT" in
  ''|*[!0-9]*)
    echo "error: PROXY_PORT must be a number (got '$PROXY_PORT')" >&2
    exit 1
    ;;
esac
if [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
  echo "error: PROXY_PORT must be between 1 and 65535 (got $PROXY_PORT)" >&2
  exit 1
fi
case "$CELLULAR_APN_AUTH_TYPE" in
  ''|PAP|CHAP) ;;
  *)
    echo "error: CELLULAR_APN_AUTH_TYPE must be PAP, CHAP or empty (got '$CELLULAR_APN_AUTH_TYPE')" >&2
    exit 1
    ;;
esac

uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:lower:]' '[:upper:]'
  else
    python3 -c 'import uuid; print(str(uuid.uuid4()).upper())'
  fi
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

HOST_XML="$(xml_escape "$PROXY_HOST")"
ORG_XML="$(xml_escape "$ORG")"

# apn_extras <user name> <password>
# Optional keys of one APN entry. The global CELLULAR_APN_USERNAME / CELLULAR_APN_PASSWORD win over
# the per-carrier defaults; a key is omitted entirely when its value is empty so the device default
# applies.
apn_extras() {
  local user="${CELLULAR_APN_USERNAME:-$1}" pass="${CELLULAR_APN_PASSWORD:-$2}"
  local extras=""
  if [ -n "$CELLULAR_APN_AUTH_TYPE" ]; then
    extras+="          <key>AuthenticationType</key>
          <string>${CELLULAR_APN_AUTH_TYPE}</string>
"
  fi
  if [ -n "$user" ]; then
    extras+="          <key>Username</key>
          <string>$(xml_escape "$user")</string>
"
  fi
  if [ -n "$pass" ]; then
    extras+="          <key>Password</key>
          <string>$(xml_escape "$pass")</string>
"
  fi
  printf '%s' "$extras"
}

# login_summary <user name> <password>   (for the log line only; the password is not printed)
login_summary() {
  local user="${CELLULAR_APN_USERNAME:-$1}" pass="${CELLULAR_APN_PASSWORD:-$2}"
  if [ -z "$user" ] && [ -z "$pass" ]; then
    printf 'no login'
  else
    printf 'login %s / %s' "${user:-<none>}" "$([ -n "$pass" ] && printf '********' || printf '<none>')"
  fi
}

# apn_entry <apn> <apn user name> <apn password>
# One <dict> of the cellular payload's APNs array: the APN name, its optional login, and the proxy.
# Shared by the single-carrier profiles and the universal bundle so every entry stays identical.
apn_entry() {
  local apn_xml extras
  apn_xml="$(xml_escape "$1")"
  extras="$(apn_extras "$2" "$3")"
  cat <<EOF
        <dict>
          <key>Name</key>
          <string>${apn_xml}</string>
${extras}          <key>ProxyServer</key>
          <string>${HOST_XML}</string>
          <key>ProxyPort</key>
          <integer>${PROXY_PORT}</integer>
        </dict>
EOF
}

# write_profile <slug> <file name> <display name> <apn> <apn user name> <apn password>
# Every profile gets its own PayloadIdentifier suffix and fresh UUIDs so iOS treats them as
# distinct profiles rather than updates of one another.
write_profile() {
  local slug="$1" file="$2" name="$3" apn="$4" user="$5" pass="$6"
  local out="$OUT_DIR/$file"
  local profile_uuid apn_uuid apn_xml name_xml apns
  profile_uuid="$(uuid)"
  apn_uuid="$(uuid)"
  apn_xml="$(xml_escape "$apn")"
  name_xml="$(xml_escape "$name")"
  apns="$(apn_entry "$apn" "$user" "$pass")"

  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.cellular</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadIdentifier</key>
      <string>${PROFILE_ID}.${slug}.cellular</string>
      <key>PayloadUUID</key>
      <string>${apn_uuid}</string>
      <key>PayloadDisplayName</key>
      <string>${name_xml} Cellular Proxy</string>
      <key>PayloadDescription</key>
      <string>Routes ${name_xml} cellular data (APN ${apn_xml}) through the SL_Proxy listener on ${HOST_XML}:${PROXY_PORT}.</string>
      <key>APNs</key>
      <array>
${apns}      </array>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>SL_Proxy ${name_xml} Cellular Proxy</string>
  <key>PayloadDescription</key>
  <string>Sets the ${name_xml} APN (${apn_xml}) and points cellular data at the SL_Proxy user-space listener (${HOST_XML}:${PROXY_PORT}). Keep SL_Proxy open and connected while this profile is installed.</string>
  <key>PayloadIdentifier</key>
  <string>${PROFILE_ID}.${slug}</string>
  <key>PayloadOrganization</key>
  <string>${ORG_XML}</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>${profile_uuid}</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$out"
  elif command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$out"
  fi
  echo "Wrote $out  (APN ${apn}, $(login_summary "$user" "$pass"), proxy ${PROXY_HOST}:${PROXY_PORT})"
}

# File name of the unified bundle; keep in step with Carrier.universalProfileFileName in
# SL_Proxy/Core/Carrier.swift.
UNIVERSAL_FILE="Universal-Cellular-Proxy.mobileconfig"

# write_universal_profile
# One profile with a single com.apple.cellular payload whose APNs array lists every carrier entry.
# iOS applies the entry that matches the inserted SIM, so this one profile covers MTN, Glo, Airtel
# and 9mobile and a tester no longer has to pick the right single-carrier file.
write_universal_profile() {
  local out="$OUT_DIR/$UNIVERSAL_FILE"
  local profile_uuid apn_uuid apns=""
  profile_uuid="$(uuid)"
  apn_uuid="$(uuid)"

  local entry slug file name apn user pass
  for entry in "${CARRIERS[@]}"; do
    IFS='|' read -r slug file name apn user pass <<< "$entry"
    apns+="$(apn_entry "$apn" "${user:-}" "${pass:-}")
"
  done

  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.cellular</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadIdentifier</key>
      <string>${PROFILE_ID}.universal.cellular</string>
      <key>PayloadUUID</key>
      <string>${apn_uuid}</string>
      <key>PayloadDisplayName</key>
      <string>Universal Cellular Proxy</string>
      <key>PayloadDescription</key>
      <string>Routes cellular data for Airtel, MTN, Glo and 9mobile through the SL_Proxy listener on ${HOST_XML}:${PROXY_PORT}. iOS applies the APN that matches the inserted SIM.</string>
      <key>APNs</key>
      <array>
${apns}      </array>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>SL_Proxy Universal Cellular Proxy</string>
  <key>PayloadDescription</key>
  <string>One profile for every supported Nigerian carrier (Airtel, MTN, Glo, 9mobile). Points cellular data at the SL_Proxy user-space listener (${HOST_XML}:${PROXY_PORT}); keep SL_Proxy open and connected while this profile is installed.</string>
  <key>PayloadIdentifier</key>
  <string>${PROFILE_ID}.universal</string>
  <key>PayloadOrganization</key>
  <string>${ORG_XML}</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>${profile_uuid}</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$out"
  elif command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$out"
  fi
  echo "Wrote $out  (APNs for ${#CARRIERS[@]} carriers, proxy ${PROXY_HOST}:${PROXY_PORT})"
}

mkdir -p "$OUT_DIR"

for entry in "${CARRIERS[@]}"; do
  IFS='|' read -r slug file name apn user pass <<< "$entry"
  write_profile "$slug" "$file" "$name" "$apn" "${user:-}" "${pass:-}"
done

write_universal_profile

echo
echo "Generated ${#CARRIERS[@]} carrier profiles + 1 universal bundle in $OUT_DIR"
echo "  payload type:      com.apple.cellular"
echo "  proxy:             ${PROXY_HOST}:${PROXY_PORT}"
echo "  APN auth:          ${CELLULAR_APN_AUTH_TYPE:-<device default>}"
echo "  APN login:         per carrier (Airtel internet/internet; MTN, Glo, 9mobile none)${CELLULAR_APN_USERNAME:+, overridden by CELLULAR_APN_USERNAME}"
echo "  global HTTP proxy: omitted (INCLUDE_GLOBAL_HTTP_PROXY pinned to ${INCLUDE_GLOBAL_HTTP_PROXY})"
