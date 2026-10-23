"use strict";
const $ = (id) => document.getElementById(id);
let saved = null;

function announce(text) {
  $("status").textContent = "";
  setTimeout(() => { $("status").textContent = text; }, 50);
}

function clearError() {
  $("error").textContent = "";
  for (const node of document.querySelectorAll("[aria-invalid]")) {
    node.removeAttribute("aria-invalid");
    node.removeAttribute("aria-errormessage");
  }
}

function showError(message, field) {
  $("error").textContent = message;
  if (field) {
    field.setAttribute("aria-invalid", "true");
    field.setAttribute("aria-errormessage", "error");
    field.focus();
  }
}

/** Points the error at the field it's about, so focus lands where the fix is. */
function fieldFor(message) {
  if (/token/i.test(message)) return $("token");
  if (/direct address/i.test(message)) return $("direct");
  if (/url|https/i.test(message)) return $("url");
  return null;
}

function fill(server) {
  if (!server) return;
  $("name").value = server.name || "";
  $("direct").value = server.directAddress || "";
  $("url").value = server.url || "";
  $("tailscaleOnly").checked = Boolean(server.tailscaleOnly);
}

function form() {
  return {
    name: $("name").value,
    directAddress: $("direct").value,
    url: $("url").value,
    tailscaleOnly: $("tailscaleOnly").checked,
    token: $("token").value,
  };
}

function setBusy(busy) {
  for (const id of ["test", "save", "useLink", "forget"]) $(id).disabled = busy;
  document.body.setAttribute("aria-busy", busy ? "true" : "false");
}

function renderChecks(checks) {
  const list = $("results");
  list.replaceChildren();
  for (const check of checks) {
    const item = document.createElement("li");
    const result = document.createElement("span");
    result.className = check.ok ? "ok" : "failed";
    result.textContent = check.ok ? "✓ Connected" : "✕ Not connected";
    const route = document.createElement("div");
    route.textContent = check.route;
    const detail = document.createElement("div");
    detail.className = "hint";
    detail.textContent = check.ok ? `Answered in ${check.milliseconds} ms` : check.message;
    item.append(result, route, detail);
    list.append(item);
  }
  $("resultsSection").hidden = checks.length === 0;
}

function showCurrent(state) {
  $("current").hidden = !state.server;
  if (!state.server) return;
  const status = state.status || {};
  const name = state.server.name || state.server.directAddress || state.server.url;
  $("currentText").textContent = status.connected
    ? `Paired with ${name}. Connected: ${status.route}.`
    : `Paired with ${name}.${status.message ? ` Last problem: ${status.message}` : ""}`;
}

async function useLink(link) {
  clearError();
  const value = (link ?? $("link").value).trim();
  if (!value) return showError("Paste the pairing link first.", $("link"));
  const result = await window.gateway.parseLink(value);
  if (result.error) return showError(result.error, $("link"));
  fill(result.server);
  $("token").value = result.token;
  $("link").value = "";
  announce(`Filled in ${result.server.name || "the Mac"} from the pairing link. Review it, then choose Save and connect.`);
  $("save").focus();
}

async function run(action) {
  clearError();
  setBusy(true);
  announce(action === "save" ? "Connecting to the Mac…" : "Testing the connection…");
  try {
    const result = await window.gateway[action](form());
    if (result.checks) renderChecks(result.checks);
    if (result.error) {
      showError(result.error, fieldFor(result.error));
    } else if (action === "test") {
      const ok = result.checks.filter((check) => check.ok).length;
      announce(ok ? `${ok} of ${result.checks.length} routes connected.` : "No route reached the Mac.");
    }
  } catch (error) {
    showError(error.message || String(error));
  } finally {
    setBusy(false);
  }
}

async function init() {
  const state = await window.gateway.state();
  saved = state.server ? state : null;
  if (saved) {
    $("title").textContent = "Connection";
    fill(state.server);
    $("token").placeholder = `Saved token ending in ${state.tokenSuffix}`;
    $("token").setAttribute("aria-describedby", "tokenHint");
    $("tokenHint").textContent = `Leave empty to keep the saved token ending in ${state.tokenSuffix}.`;
  }
  showCurrent(state);
  if (state.link) await useLink(state.link);
  else $("title").focus();
  if (state.notice) announce(state.notice);
}

$("form").addEventListener("submit", (event) => {
  event.preventDefault();
  run("save");
});
$("test").onclick = () => run("test");
$("useLink").onclick = () => useLink();
$("link").addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    useLink();
  }
});
$("showToken").onclick = () => {
  const show = $("token").type === "password";
  $("token").type = show ? "text" : "password";
  $("showToken").textContent = show ? "Hide" : "Show";
  $("showToken").setAttribute("aria-pressed", String(show));
};
$("forget").onclick = async () => {
  if (!confirm("Forget this Mac?\n\nThis PC disconnects and removes the saved pairing token. Nothing changes on the Mac.")) return;
  setBusy(true);
  try {
    await window.gateway.forget();
    saved = null;
    for (const id of ["name", "direct", "url", "token"]) $(id).value = "";
    $("tailscaleOnly").checked = false;
    $("token").placeholder = "";
    $("tokenHint").textContent = "From Cantrip's Remote control settings on the Mac.";
    $("title").textContent = "Connect to your Mac";
    showCurrent({ server: null });
    announce("Forgot the Mac. Pair again to reconnect.");
    $("title").focus();
  } catch (error) {
    showError(error.message || String(error));
  } finally {
    setBusy(false);
  }
};
$("openLog").onclick = () => window.gateway.openLog();
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && saved) window.close();
});
window.gateway.onLink((link) => { if (link) useLink(link); });
window.gateway.onStatus((status) => { if (saved) showCurrent({ server: saved.server, status }); });
init();
