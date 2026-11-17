// SL_Proxy OTA logic. Runs in a sandboxed JavaScriptCore context: no network, no files, no timers.
// The app offers these functions:
//   setToast(message)             show a short message at the top of the app
//   applyProxyConfig(link)        add the server from a share link (ss://, vmess://, vless://, trojan://,
//                                 socks://, ...) if it is new and make it the active one; returns true
//                                 when the link was understood. A running tunnel switches by itself.
//   setRoutingMode(mode)          "rule", "global" or "direct"; returns true when the mode is known
//   getAppState()                 { appVersion, build, otaVersion, activeNodeID, activeNodeName,
//                                   nodeCount, tunnelStatus, connected, port, routingMode,
//                                   navigationStyle }
//   getFlag(key, fallback) / setFlag(key, value)   feature flags (booleans) shared with the app
//   openURL(url)                  open an http(s) link in Safari
//   console.log(message)          written to the device log
//
// Functions named in ui.json ("action": { "type": "js", "fn": "..." }) must exist here, otherwise
// the whole update is rejected and the app keeps the previous version.

// Called once after this bundle becomes active.
function onLoad() {
  var state = getAppState();
  console.log("OTA bundle active, app " + state.appVersion + ", routing " + state.routingMode);
}

// Toggle "Smart routing": receives the new value.
function onSmartRouting(enabled) {
  setRoutingMode(enabled ? "global" : "rule");
  setToast(enabled ? "Smart routing on: all traffic uses the proxy" : "Smart routing off: rules decide");
}

// Button "Route everything through the proxy".
function routeGlobal() {
  setFlag("smartRouting", true);
  setRoutingMode("global");
  setToast("Global routing enabled");
}

// Example of a custom routing action. Point a ui.json button at it with
//   "action": { "type": "js", "fn": "useServer", "args": ["socks://user:pass@host:1080#Name"] }
function useServer(link) {
  if (!link || !applyProxyConfig(link)) {
    setToast("That server link could not be used");
    return false;
  }
  setToast("Server updated");
  return true;
}

// Example of server-side pricing logic; call it from native code with ota.call("computePrice", ...).
function computePrice(base, plan) {
  var discount = plan === "yearly" ? 0.2 : 0;
  return Math.round(base * (1 - discount) * 100) / 100;
}
