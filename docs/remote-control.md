[User Guide](README.md) / Remote control

# Control Cantrip from another device

Remote control uses the **same live sessions on your Mac**. AgentGateway is
an iPhone/iPad client; another Mac can use Cantrip's **Remote** tab. A browser
can use the host's web client through Tailscale Serve.

Long user prompts appear as compact plain-text previews. Choose **Read full
prompt** to page through the complete text; the browser reader also offers
**Download all**. Preview limits do not truncate submitted text. The host
prepares memory context and encodes transcript responses off the UI thread.
Requests remain single messages, and uncertain sends are still never
automatically replayed.

## Automatic Remote interface updates

Mac Remote and the browser client detect host interface changes through their
existing session polling. A content-based `uiRevision` changes with the host's
HTML, styles or scripts, not with ordinary chat updates or an unchanged restart.
The page reloads automatically when connected and idle on the latest output.
Typing, text composition, active submissions, tab dragging, history loading and
open dialogs (including Secure Input and View Mac) defer the reload. Reading
older history also defers it until you return to the latest output.

The selected chat, ordinary drafts in other tabs, delivery mode and pending
question reply target survive the reload. Replies are never resent automatically;
an expired question draft cannot silently turn into a new task or an answer to
another question. Failed-action warnings remain visible. Secure fields, sign-in
codes, pairing tokens and transcripts are not copied into reload state.
Ordinary drafts are temporarily stored in this browser tab's `sessionStorage`,
bound to a fingerprint of the current pairing and consumed once after loading.
Unpairing clears that state. If it cannot be saved, the current page stays open
and shows an error rather than risking draft loss.
Controls briefly lock during navigation so a new submission cannot race the
reload. A navigation timeout restores the original controls and drafts; a
host returning the old interface pauses automatic refresh to avoid a loop.

The host must run the updated build. Pages opened before this feature need
**one initial reload** to acquire the update detector; subsequent interface
updates are automatic. The same host-served fix covers Mac Remote without a
separate client rebuild. Older hosts without `uiRevision` keep normal polling.

## Persistent Private Local tab

**Private Local** is always present in the host's tabs and its paired Remote
clients. **Local means self-hosted, not limited to the Cantrip host computer.**
The model server can run on your NAS, another computer or another server you
control. The connection is **AgentGateway/Cantrip Remote -> Cantrip Mac ->
your self-hosted LLM server**. Its identity, history and self-hosted route survive
restarts. It cannot
be closed, cleared, unlocked or converted into a cloud-backed tab. It is separate
from the older **Private mode**, which disables saving and hides a tab from Remote.

1. Run a trusted Ollama installation on your chosen server and install a model
   there. The server must be reachable from the Cantrip Mac.
2. Right-click **Private Local** on the Mac, or open the tab's three-dot menu in
   Mac/browser Remote, and choose **Private Local Settings**. AgentGateway has the
   same action in its chat menu and tab actions.
3. Set the server's base URL, choose **Load server models**, and select an
   installed model. Set context tokens and the
   optional system prompt, then save while idle.

The phone never calls Ollama directly: its paired connection controls the Mac.
Use HTTPS for another machine, for example `https://llm.your-tailnet.ts.net` or
`https://your-server.example/ollama`. LAN hostnames/IPs and reverse-proxy base
paths are supported with HTTPS and a trusted certificate. A Tailscale Serve
HTTPS URL lets you keep the service private without exposing it publicly.
Plain HTTP is accepted only on loopback (for example `http://127.0.0.1:11434`);
that address still means the Cantrip Mac, not the phone. URL credentials,
query parameters, fragments and automatic redirects are rejected. Normal TLS
certificate validation remains enabled.

Ollama's installed model list and local architecture metadata are checked on
the **configured server** before each prompt. Cloud-tagged models and Ollama
cloud aliases are rejected. Missing models or a stopped server fail
visibly without using Copilot, Claude, Codex, Hermes, or any cloud fallback.
Settings use revision checks so another device cannot overwrite a stale form.
Loading models never submits a conversation or downloads a model.

The tab currently supports **text chat**, not attachments or agent tools.
Shell/slash commands are treated as text; tools, MCP, Council, ambient context,
shared memory injection/logging and cross-tab continuity digests are disabled.
Auto delivery queues locally; Redirect and Stop remain available. The transcript
uses plain text rather than fetching Markdown images or opening model-generated
links. Drafts are isolated by tab, and no private completion summaries go to APNs.
On-Mac dictation requires on-device recognition.

History and durable run events remain on the Mac with user-only file permissions;
context is bounded when sent to the model, even though saved history is retained.
Choose a context size supported by the model and available memory. This is **not
incognito or additional encryption at rest**: the Mac account, backups and paired
devices can access the saved conversation. Prompts and selected history are sent
to your configured server for inference; that server's own logging/storage policy
also applies. Only configure a server you control and trust, not a gateway that
forwards inference to a managed cloud provider. A URL alone cannot prove server
ownership. This tab currently uses the native Ollama API; the global Local Model
backend's arbitrary OpenAI-compatible endpoints are not reused.

Both native apps need updated builds and the host must reopen to activate it.
The paired API advertises `isLocalPrivate`/`supportsPrivateLocalSettings`, with
`GET/POST /api/v1/sessions/{id}/private-settings` and read-only
`GET /api/v1/sessions/{id}/private-models?baseURL=...`.

## Per-tab model, effort and context window

Choose **Model Settings** in the Mac/browser Remote tab's settings menu
(the three dots). AgentGateway exposes the same controls in the chat menu and
tab actions. On the host Mac, right-click a local tab and choose **Model
Settings**. These controls currently apply to the Mac's **Copilot** backend
with Council mode off; they do not reconfigure Claude, Codex or ACP servers.

Turn off **Use Mac defaults** to save a model, reasoning effort and context tier
for just that tab. The choices come from the paired Mac's Copilot model catalog,
not the phone's account. Unsupported effort/context combinations cannot be saved.
**Refresh models** refreshes account metadata only; **Reload settings** discards
the form's draft and reads the current tab settings. Catalog failures retain the
cached options and display the error. Standard/Long numbers are input budgets;
the separately labeled advertised maximum is not a promise of total context
for each tier. Long context can have different costs.

Save only when the tab, its queue and persistent shell are idle. The host
rechecks at save time and rejects stale revisions, so another device's changes
cannot be overwritten by an old form. Other tabs and the Mac's global defaults
are unchanged. Settings survive reopening the tab/app. Returning to **Use Mac
defaults** removes the tab override.

The next prompt uses the new settings. The visible transcript is preserved;
Copilot starts a fresh runtime using Cantrip's recent-history continuity, not
the old model's entire internal context. No running prompt is stopped or
replayed. Both apps need updated builds; the Mac must be reopened to activate
the paired `GET/POST /api/v1/sessions/{id}/model-settings` endpoint.

## Remote approvals and secure input

Cantrip, Mac/browser Remote and AgentGateway display questions, approvals and
other non-secret actions **inline in the conversation**. Ordinary questions use
the normal chat composer with **Auto** delivery, including attachments, or the
suggested-answer buttons. Select **Reply in chat** when several questions are
waiting. Explicit Queue/Redirect/Inject modes keep their existing meaning.
**View Questions in Chat** opens the conversation; it does not open a modal.
Only **passwords and passphrases** use the **Secure Input** modal, opened by
**Enter password securely**. Requests belong to the original tab and execution, accept one response
only, and expire after ten minutes. Stop, redirect, privacy changes and backend
termination invalidate pending requests. Another device's answer removes the
request on refresh. Requests and secrets are not restored/replayed after a crash.

| Request | Supported behavior |
|---|---|
| Copilot SDK tool permission | Approve once or deny when tools are enabled and **Act on my behalf** is off. Read permissions retain the existing policy. |
| Claude Code permission / AskUserQuestion | Stdio permission requests and questions wait for a response. Questions are answered sequentially. |
| Copilot ACP permission | Offered `allow_once` / `reject_once` options only; no implicit always-allow fallback for an interactive answer. |
| Password/passphrase or SSH confirmation | Verified `/usr/bin/ssh`, `ssh-add`, `ssh-keygen`, and `sudo -A` children of Cantrip `!` commands or native Copilot/Claude/Codex processes use the secure askpass channel. |
| GitHub login / provider 2FA | Run `/login github` in an idle non-private-local tab, or choose **Sign in to GitHub on Mac** in tab actions. Open the fixed GitHub device-login page and enter its temporary code. GitHub handles password/2FA; Cantrip waits for `gh` to confirm success. |
| macOS Touch ID, Keychain or TCC dialog | Not intercepted or auto-approved. Use the Mac's required authorization UI. Phone approval is not a replacement for macOS authorization. |

**Act on my behalf** and provider-specific automatic permissions are preserved.
Turn automatic actions off to require tool approvals. Read-only Council seats
remain read-only; the Private Local tab remains tool-free. Codex's headless
`exec` tool-approval protocol, arbitrary programs, manual persistent-terminal
input, and arbitrary OAuth callback flows are not covered by this bridge.

Secure fields are separate from ordinary chat. Non-secret questions and their
answers become normal saved conversation turns and are sent to the agent;
**never enter passwords in ordinary chat**. Secure answers go through the authenticated connection directly to an
OS-verified askpass requester, not to the model, transcript, journal, command
arguments or push payload. The broker verifies user, executable, process
ancestry and the current execution before sending a response. Background
children from an older turn cannot claim credentials for a newer turn.
SSH uses askpass automatically; sudo needs its explicit `-A` option. No blanket
password-prompt scraping or permission bypass is performed. The requesting
program and destination must still be trusted.

`gh` must be installed for GitHub sign-in. The CLI may save its resulting
credential in the Mac's normal credential store. A pending device code stays
only in the live inline request UI, never in saved chat history or push.

The paired API exposes `GET /api/v1/sessions/{id}/input` and
`POST /api/v1/sessions/{id}/input/{requestID}` with a `decision` and optional
`text`. Chat replies use `POST /api/v1/sessions/{id}/messages` with an explicit
`inputRequestID` and Auto delivery, retaining the existing image/video transport.
Only a still-pending question can accept that ID; stale replies fail instead of
starting or queuing another task. Capabilities, pending requests and counts are
advertised in tab snapshots. New phone clients can use text-only input replies
with older hosts; attached replies require `supportsChatInputReplies`.
Responses are never automatically retried after an uncertain connection;
reload the requests instead. Existing LAN/Tailscale routes work; no relay is
required. All native clients/host need the updated build.

## Mac attention, View Mac and Face ID

Open **Mac Permissions & View Mac** from the Remote tab menu or AgentGateway's
**Settings > Cantrip Mac**. The page reports Cantrip's Screen Recording,
Accessibility, Microphone and Speech Recognition grants, plus its own Keychain
access issues. Full Disk Access is labeled for manual review; there is no
blanket public permission-status API. Touch ID & Password shows local
authentication availability, not an approval request for another app.
Fixed **Open on Mac** actions open the appropriate system settings or Keychain
Access. They do not grant permissions or unlock secrets.

When a supported Cantrip operation finds a missing permission or its own pairing
credential read is blocked, **Cantrip Mac needs attention** can be sent through
the existing opt-in input-alert subscription. No permission detail, dialog text
or credential goes to Apple. Repeated checks of the same unresolved issue do not
send repeated alerts. This is not a system-wide observer of other apps' dialogs.
If Cantrip cannot read its pairing credential at startup, Remote itself may be
unavailable and the issue needs local resolution; existing credentials are never
silently replaced.

To use View Mac:

1. On the host Mac, enable **Remote control daemon**, then **Allow paired clients
   to view and control this Mac** in Cantrip settings. It is off by default.
   Anyone holding the pairing token can request a session once this is enabled.
2. Grant Screen Recording on the Mac. Also grant Accessibility if you want
   pointer/keyboard control; view-only works without Accessibility.
3. On the remote client, explicitly start **View Mac** or enable control before
   starting. AgentGateway requires enrolled Face ID or Touch ID.
4. Choose a display, zoom and tap to click. Click the target field/window before
   sending text, Return/Tab/Escape/Delete/arrows or scroll commands. Text entry
   is masked locally but is typed into the Mac's actual focused field, which
   may not be a password field. Check focus before sending secrets.

This is a roughly one-frame-per-second assistance view, not full-rate screen
sharing or a replacement for all remote desktop features. Only one session is
allowed at a time. Each expires after five minutes, after 60 seconds without
activity, when disabled locally, or when Remote is stopped/re-paired. Leaving
the viewer or backgrounding the client clears its image/key and requests Stop;
if disconnected, the host timeout ends the lease. The Mac's panel and menu-bar
**End Remote View** action revoke it immediately.

Frames are captured in memory using ScreenCaptureKit, with per-session AES-GCM
encryption over the paired transport. Desktop commands are encrypted, sequence-
bound and tied to a recent frame/display layout. Repeated or stale commands
are rejected; ambiguous writes are not retried. No screenshots, typing or
clipboard contents are added to transcripts, journals, memory or model context
by this feature. The destination app still receives input and can store it.
The session key is delivered over the existing authenticated connection: a
third-party HTTPS-terminating proxy is in that trust path. This is not the
previously discussed end-to-end encrypted relay.

**Face ID/Touch ID is enforced by AgentGateway**, using a fresh biometric check
before an approval, action confirmation, password/passphrase submission or
starting a viewing/control lease. Ordinary chat question replies do not require
biometrics; the non-biometric response route accepts only question requests.
Authentication failure, cancellation, a changed Mac or an expired request never
proceeds. There is no silent device-passcode fallback; Deny and Cancel remain
available. The Mac/browser clients retain their paired-client authorization.
This does not provide device-attested biometric proof to the Mac or substitute
for a Mac Keychain access rule, macOS Touch ID, TCC grant or administrator login.

Protected dialogs may be blank in captures or reject injected input. Those
still require an allowed macOS authentication path or local interaction. View
Mac cannot grant its own initial capture/control permissions. Corporate
permissions remain subject to IT policy. Both native apps need updated builds.

## AgentGateway completion notifications

On iPhone/iPad, select a saved Mac and enable **Settings > Cantrip alerts >
Completion and input-needed alerts**. After a successful run and all queued
prompts finish, the Mac sends an Apple push notification with the tab name and
a short, Markdown-cleaned excerpt of the final answer. It does not ask another
model to summarize the conversation. Tap an alert to open that saved server and
tab. A removed/re-paired server is rejected; opening a notification never sends
a prompt. Private tabs, failures, Stop, redirects and intermediate automatic
recovery do not send success alerts.

Input requests also send **Cantrip needs your input**. These alerts contain no
question, command, password, device code or tab title. Tap to open the original
Mac/tab's conversation, with questions or secure-input buttons inline; tapping
never approves an action or opens an ordinary-question modal. A stale alert
cannot revive an answered or expired request. Attention alerts use the request's expiry, are
deduplicated, and unsent retries are removed when resolved. Already-delivered
Apple banners may remain. Older registration clients do not opt in to input
alerts until updated. Unsaved Private tabs and Private Local are excluded.

This needs **updated native AgentGateway and Mac builds**, plus Apple Push
Notification service (APNs) configuration on the Mac. Foreground polling cannot
deliver alerts while iOS suspends the app. Enable the Push Notifications
capability for `com.itzhoang.hermbot` in the Apple Developer account and regenerate
its provisioning profiles before the next signed upload. Debug uses APNs
development; Release/TestFlight uses production.

Create an APNs signing key authorized for that bundle ID/environment in the
same Apple Developer team. Keep its `.p8` on the Mac, outside the repository,
and create `~/.config/Cantrip/apns.json`:

```json
{
  "keyID": "YOURKEYID1",
  "teamID": "YOURTEAM01",
  "privateKeyPath": "/absolute/private/path/AuthKey_YOURKEYID1.p8"
}
```

Restrict the key and configuration to the Mac user (file mode `600`). Use an
**APNs key**, not an App Store Connect API key. Configuration is reread without
restarting Cantrip. **Check notification setup** validates local configuration
and shows the latest provider error; it does not prove that Apple accepted the
key or displayed an alert. Actual signed-device delivery still needs an
end-to-end check after provisioning.

Registration/removal uses paired `GET/POST/DELETE /api/v1/notifications`.
Opt-in is per saved Mac and survives switching tabs/servers and locking the
phone. Turn it off while connected to that Mac before removing the server.
Subscriptions expire after 90 days without renewal; reopening the app renews
the selected Mac's registration. Rotating the Mac pairing token invalidates
old registrations. The Mac stores registrations and a bounded durable delivery
queue in `~/.cache/Cantrip/notifications/state.json` in a user-only directory.
Repeated completion callbacks are deduplicated; transient delivery failures
retry with backoff, and invalid Apple device tokens are removed. Alerts expire
after an hour. APNs acceptance is not proof of device delivery, and a lost
acknowledgement can still cause a repeated presentation despite collapse IDs.

The Mac must stay running with Remote enabled and internet access to Apple;
the phone needs connectivity for push and LAN/Tailscale access to open the
conversation. Focus, notification settings and OS scheduling affect presentation.
The tab title and preview travel through Apple and may appear on the Lock Screen.
No full transcript, pairing secret or APNs signing key goes to a relay service.

## Send context during a task

Choose **Inject** in AgentGateway or Mac/browser Remote to add instructions
to a running local Copilot or Claude Code task without stopping it. **Auto**
also uses injection for messages classified as helpful same-task context.
The existing clients use the host's delivery path, so this behavior requires
the updated Mac host but no new phone API. **Queue**, **Redirect**, and **Stop**
keep their separate meanings.

The delivery status distinguishes pending submission, acceptance, and
uncertainty. Copilot consumes accepted steering at its next available model
request, not during an already committed tool call. Uncertain context sends
are not automatically replayed; the journal retains them for recovery.
Copilot Remote/ACP and unsupported backends continue to queue instead.

## Loading long conversations

Updated AgentGateway and Mac/browser Remote load recent messages first instead
of repeatedly downloading the entire live transcript. **AgentGateway and the native
Mac Remote tab start with the latest three prompt-and-reply exchanges**, including all
continuation or council replies belonging to each prompt. A new prompt counts
as the current exchange while its reply is still running.
Scroll up near the top to load older exchanges without losing your reading
position. Automatic loading stops after the current exchange plus ten earlier
exchanges; **Load more messages** continues beyond that. Older history is not
deleted, and expanded history stays open while you browse or switch cached tabs.
Every loaded message includes its complete text, reasoning, and tool input/output
by default. Reasoning/tool disclosures and long-prompt readers use content already
downloaded; they do not require another message fetch.
Older hosts that return previews retain the **Load full message and details** fallback.

Automatic reads request `?history=recent`, including mutation acknowledgements.
The host targets 30 recent messages and a 192 KiB encoded message page (at least
one complete message), then extends the start back to the first response's user
prompt when available. A large response or multi-response turn may exceed these
soft limits so its prompt stays visible before its output; messages are never
truncated to fit. The same rules apply to requested older pages. This page budget
excludes metadata and the ordered queue.
Native Mac Remote and AgentGateway add `recentExchanges=3` to recent conversation
reads. AgentGateway also includes it on session mutations so their acknowledgements
do not collapse the transcript after a follow-up. The bounded opt-in (1-3) is
validated before any mutation and returns up to three complete exchanges even
when their combined output exceeds the usual soft page budgets. A running prompt
counts as the newest exchange; older-page requests retain normal paging.
Browsers and clients without the opt-in keep their existing page sizes. Legacy hosts
without pagination retain the full transcript rather than hiding inaccessible history.
Page sizing and encoding run off the main actor and the lightweight tab-list queue.
Clients cache up to five tabs. AgentGateway and native Mac Remote keep three complete exchanges
until you expand history; other unattended clients target a rolling 120-message
window while retaining the boundary prompt and responses. Older-history loading
can expand these windows.

Session summaries advertise `supportsPagedHistory` and `historyRevision`.
Unchanged summaries need no detail download. A conditional detail read with
`revision=<historyRevision>` returns `{"unchanged":true}` if still current,
without constructing the message payload. `before=<first-message-UUID>` requests
the previous page; `hasOlderMessages` and `historyStartID` identify pagination
and conversation resets. A missing cursor returns 409, prompting a refresh.
Authenticated `GET /api/v1/sessions/{id}/messages/{messageID}` returns full
message details, using a separate host encoding queue.

Tab-list polling remains single-flight: about 1.5 seconds between active/error refreshes,
5 seconds while idle, and paused while the client is inactive/hidden. A
successful tab-list read is applied immediately. A failed conversation read
keeps cached messages and reports a separate error, rather than treating a
reachable host as disconnected. Lightweight native HTTPS/LAN read deadlines remain
3/2 seconds; conversation pages and full-message reads allow 20 seconds, while
LAN connection establishment still times out after 2 seconds. AgentGateway history
downloads do not hold its polling/mutation gate, and tab polling continues during
a slow recent-page download. Uncertain writes are never replayed.

Update both apps and reopen the host when active work has finished to enable
this behavior. Old clients retain the full-snapshot API, and new clients can
still read older hosts without pagination. Paging covers history currently
available in the live host session; it does not restore archived disk history.

## Liveness, readiness, and stall diagnostics

`GET /health` returns the pre-encoded `{"status":"ok"}` response on the host's
network queue, without waiting for MainActor or transcript JSON encoding.
It requires no HTTP bearer token (the native LAN transport still requires its
TLS pairing key). This is **liveness only**, not proof that sessions are usable.

Pairing-authenticated `GET /api/v1/ready` exercises the same MainActor session
snapshots and JSON queue as `GET /api/v1/sessions`. It returns `status: "ready"`
and the non-private session summaries, or 503 if the session manager is absent.
It is a read-only snapshot check, not a backend/provider or disk-durability
check. A blocked session handler/encoder delays readiness even when health is
fast. Both native clients continue to use authenticated session reads for
route recovery; neither promotes a connection based on `/health`.

The Mac log's `remote-request:` entries contain generated request IDs,
allowlisted route/method labels, status, response bytes, outcome, and monotonic
millisecond timings for receiving/parsing, MainActor wait, handler work,
snapshots, journal wait, JSON queue wait/encoding, and response sending.
Responses include `X-Cantrip-Request-ID` for correlation. These entries contain
no pairing tokens, session IDs, raw paths, request/response bodies, or chat text.
Other existing app log categories may contain sensitive information; do not
share the entire log unredacted.

Requests still pending after one second log their current stage, then every
five seconds. Response writes have a 15-second deadline and log numeric network
errors or `send_timeout` before closing the socket. `sent` means Network.framework
processed the bytes, not that the remote client received or displayed them.
This does not change client read budgets or make timed-out mutations safe to
replay. A mutation's successful response waits for its pending journal writes;
a storage failure returns an explicit HTTP 500 warning that the action may
already have applied.

For another stall, compare timestamp-aligned host loopback and HTTPS health
**and readiness**, alongside client HTTPS and authenticated TLS-PSK LAN session
reads. Fast health with slow readiness identifies session-path contention;
fast host loopback with slow HTTPS points beyond that handler. Host-only probes
cannot establish what happened on the remote client's tunnel/network path.
These changes require updating and reopening the Mac host, not an AgentGateway
release. Packaging with `make app` alone does not interrupt or update the running
process.

**You need:** a Mac with Cantrip running, an available backend on that Mac,
and access to its Settings. Native clients on the same local network do not
need Tailscale. Save a Tailscale URL for preferred access both at home and away.

## 1. Enable the host Mac

1. On the Mac that will do the work, open Cantrip with **Option+Space**.
2. Open the **gear** and enable **Remote control daemon**.
3. Leave **Port** at `8765` unless you have a reason to change it. This is
   the loopback port used for the optional Tailscale proxy, not a LAN web URL.
4. Click **Copy pairing token** and transfer it privately to your client.
5. Keep the host awake and signed in. Enable **Launch at login** if desired.

**Expected result:** no Remote error is shown in Settings. Native clients
can discover the host and authenticate using the token.

The token authorizes access to non-private sessions and their controls, plus
read-only access to saved Cantrip memory.
Do not put it in a screenshot, shared note, issue, URL, or source repository.
Remote prompts use the host's configured backend and action permissions.

## 2a. Connect AgentGateway on iPhone or iPad

**Before you start:** install a current AgentGateway build (iOS/iPadOS 26+).
AgentGateway is a separate app; installing Cantrip does not install it.
See the [AgentGateway repository](https://github.com/FlyingViet/Hermes) for its
installation information.

1. Put the phone/tablet and host Mac on the same local network.
2. In AgentGateway, open **Settings** using the **gear**.
3. In **Cantrip Remote**, paste the **Pairing token**.
4. Leave **Tailscale URL (optional, preferred when saved)** blank for LAN-only use.
5. Tap **Save and Connect**. Allow Local Network access if prompted.
6. Return to chat. Open the backend/execution picker (shown as `</>` for the
   coding choice), then choose **Cantrip Remote**.
7. Select an existing session or use the **+** control to create one.
8. Send `Reply with a short message to confirm this remote connection.`

**Expected result:** the client reports a connection and shows the host
session's live output. The work runs on the Mac, not on the iPhone/iPad.

### See queued prompts in AgentGateway

**Auto** is the default for typed and voice sends. The host Mac interprets
busy-run messages using the same [routing policy](sessions-and-council.md#how-auto-decides)
as local sends; the phone does not launch another agent. A status line explains
whether the message was queued, injected, or redirected. The delivery menu
keeps one-message Queue/Redirect/Inject overrides.

Auto requires an updated, relaunched Mac host (`supportsAutoDelivery` in
authenticated session snapshots). AgentGateway leaves your draft unsent and
shows an update notice on older hosts; manual modes still work. API messages
accept `mode: "auto"`; omitted mode also defaults to Auto.

While a response is running, choose **Queue** to always wait for current work.
The **Queued messages** card above the iOS composer shows the count and next
prompt. Tap it for the full pending prompts in execution order, including
those queued from the Mac or another device. A prompt leaves the queue when
it starts or is delivered into the current task. Messages being classified
are already accepted and appear in this queue until delivery is decided.

Both apps must be current: the Mac's authenticated session detail includes
the ordered queue IDs and text. Older hosts provide only a count; AgentGateway
shows an update notice rather than an empty queue. Update and relaunch Cantrip
on the host to enable queue contents. Disconnected clients show the last
known queue until they reconnect.

Tap a queued prompt's **trash button**, or swipe left and tap **Remove**, to
remove it without stopping the active task. This requires the host's
`supportsQueueRemoval` capability. AgentGateway disables removal while
disconnected or a mutation is pending and waits for the authoritative snapshot.
The authenticated `DELETE /api/v1/sessions/{sessionID}/queue/{promptID}` endpoint
uses the stable prompt ID and the same durable removal as the Mac UI. A prompt
that has already started or been removed returns HTTP 409; no other prompt or
running task is affected.

### Browse saved memory in AgentGateway

Open **hamburger menu > Cantrip Memory** to see core facts/conventions,
preferences, saved procedure notes, and daily session logs on the connected
Mac. Filenames, sizes, and modification times appear in categorized sections.
Search finds matching filenames throughout the memory folder. Opening a core
file also shows its character cap and usage when the whole file fits on a page.

Update AgentGateway and reopen an updated Cantrip host first. The viewer uses
existing paired LAN/Tailscale access and never edits or creates memory files,
records retrieval usage, or invokes an agent. Disabling memory for conversations
does not prevent viewing previously saved files.

Authenticated `GET /api/v1/memory?q=<filename-search>&after=<cursor>` returns
`enabled`, `exists`, up to 50 `documents`, and an optional `nextCursor`.
Entries contain `id`, `category`, byte size, modification time (Unix seconds),
and an optional core `characterLimit`. `GET /api/v1/memory/document?id=<id>`
returns the selected file's metadata, saved text, `offset`, `nextOffset`, and
`revision`. Subsequent reads supply `offset` and the same `revision`; a changed
file returns 409 so the reader can reload instead of mixing versions.
File pages are at most 16 KiB and preserve UTF-8 boundaries.

Only regular, non-hidden `.md` files directly in the configured memory folder
or its `sessions` directory are exposed. Symlinked entries and hard links
are excluded, and client paths cannot escape that scope. All writes return
405. Disk reads use a separate utility queue; mobile requests use the 20-second
content deadline without holding the chat polling/mutation gate. No file text
is prefetched or persisted as a mobile offline copy. Server changes reset the
viewer, and old hosts show an update notice rather than an empty memory list.

### Update and rebuild this Mac from AgentGateway

Use **Settings > Cantrip Mac > Update & Rebuild Cantrip** in an updated
AgentGateway. The host needs this API installed and reopened once first.
The app must run as `Cantrip.app` beside its source checkout's `.git` and
`Makefile`; existing Git authentication, Xcode, and signing configuration
remain on the Mac.

**Check for Updates** fetches `origin/main` and reports the branch, local edits,
and newer commit count. **Update & Rebuild** requires clean `main`, uses a
fast-forward-only merge, and runs `make app`. **Rebuild Current Source** skips
pulling and includes local edits, but refuses unresolved merge conflicts.
No action stashes, resets, rebases, or discards work. Build output is limited
to its latest 16,000 characters; errors remain visible.

Building leaves the current app running. **Restart Cantrip** is separate and
explicitly confirmed, verifies the installed signature, flushes session
journals, rechecks for active work, then quits cleanly and reopens that exact
bundle. Builds and restart refuse busy tabs, queues, and persistent shell
commands, including private sessions; they never cancel a run. New work that
starts during a build is left alone and blocks a subsequent restart.

Pairing-authenticated `GET /api/v1/maintenance` returns build identities,
availability, an opaque `revision`, aggregate busy-tab count, latest operation,
and accepted request IDs. `POST` accepts exactly `id` (UUID), `revision` (from
the latest status), and `action` (`check`, `update`, `rebuild`, `restart`);
it returns 202 while the Mac continues independently of the phone. It accepts
no client-specified shell commands, repository paths, or branches.

The latest job and 64 request receipts persist in user-only
`~/.cache/Cantrip/maintenance/state.json`. Retrying an accepted ID does not
rerun it; reusing an ID for a different request fails. Every accepted operation
rotates the revision, so even an old retry whose receipt was evicted cannot
start work again. A lost mobile acknowledgement retains the same pending
request per saved Mac; polling reconciles it without repeating the mutation.
Only foreground status polling pauses when iOS backgrounds.

If the Mac app exits during a build, the next host reports it interrupted,
not successful; inspect the checkout before retrying. Restart errors are
logged to `~/Library/Logs/Cantrip-restart.log`. This updates only the selected
Mac, not other hosts or the iPhone app.

### See Copilot account usage in AgentGateway

Tap the **usage gauge beside the Local/Remote lane picker (antenna)** in
AgentGateway's top header. It shows **AI credits used / total** in compact
form, with full amounts and a secondary percentage progress bar in the details.
Details also include reset time, additional usage, and the Copilot account
signed in on the Mac. It is available from every chat lane;
it does not switch sessions or change which backend receives your messages.

Update both apps and reopen the Cantrip Mac host. The Mac needs Node.js and a
recent Copilot CLI with the account SDK (tested with CLI 1.0.83); sign in through
Copilot. The reader discovers the installed SDK/runtime, makes account-only
calls, and stops its separate runtime without creating a session or invoking
a model. It replaces the old billing-report estimate in the Mac's **Usage** panel.

Pairing-authenticated, read-only `GET /api/v1/copilot/usage` returns a cached
snapshot immediately and starts a background lookup at most once a minute.
Mac and mobile share that cache. Only allowlisted quota/subscription fields
leave the Mac, never the SDK authentication payload or credentials. The phone
polls while foregrounded; pull-to-refresh does not bypass the host throttle.
Re-pairing clears the phone's old account snapshot.

Credit/token amounts use the reported credit units directly, not prompt counts.
Missing amounts remain unavailable, not inferred from rounded percentages.
Legacy plans retain request labels and unlimited allowances remain unlimited.
Resets come from the raw account's
UTC reset date, not the SDK's synthesized snapshot-time fallback. Unknown
resets stay unknown. Failed refreshes retain explicitly stale readings;
snapshots also become stale after five minutes without retrieval, ten minutes
of source age, or a passed reset. Older hosts show an update notice. This is
not a live model-specific or short-term rate-limit meter.

### See GitHub builds in AgentGateway

Open the mobile **hamburger menu > GitHub Builds** from any chat lane.
This read-only dashboard separates running jobs, queued/eligible jobs, and
workflow waits across configured app repositories. It shows the app, workflow
run number/attempt, job, current step, branch/commit, elapsed time, runner
online/busy state, and a link to GitHub.

Update and reopen **both apps** first. On the Cantrip Mac, install GitHub CLI
and sign in with `gh auth login`. The login needs access to each repository's
Actions and runner list (for a fine-grained token, **Actions: read** and
**Administration: read**). GitHub credentials remain on the Mac; the mobile
client uses its existing Cantrip pairing token.

Create `~/.config/Cantrip/github-builds.json` on the host with an explicit
list of repository-scoped runner registrations, using exact runner names:

```json
[
  {"repository": "your-account/ios-app", "app": "My iOS App", "runner": "ios-mac"},
  {"repository": "your-account/reader", "app": "Reader", "runner": "reader-mac"}
]
```

Each repository appears once; up to 20 entries are supported. Different
registrations can share one physical Mac. This dashboard does not serialize,
start, cancel, or change builds. Edits to the configuration are read at the
next GitHub refresh; do not put tokens in this file.

Authenticated `GET /api/v1/github/builds` returns an immediate cached snapshot
and triggers a background refresh at most once per minute while polled.
The client polls only while the screen is visible and foregrounded. Refresh
and pull-to-refresh read that cache without bypassing the host's rate limit.
Runners are matched by assigned ID or by **all** requested labels for
unassigned jobs; jobs assigned to other runners and GitHub-hosted jobs with
nonmatching labels are excluded. Workflows whose jobs/labels aren't available
yet are shown separately with unknown runner eligibility.

Waiting work is sorted by workflow creation time, **not a guaranteed FIFO
queue**. Approval, dependencies, concurrency rules, and other eligible runners
can change when or where it starts. Completed jobs disappear on refresh.
The current run attempt is used after retries. Per-repository failures retain
the last snapshot with an explicit warning and timestamp; missing setup,
authentication failures, or incomplete/pagination-limited results never
masquerade as an empty queue. Data older than two minutes is marked stale.
Scans are bounded to 1,000 results per list, 100 active workflows and 500
displayed jobs per repository; exceeding a bound surfaces an explicit warning.
GitHub has its own reporting lag, so a busy runner can temporarily have no
matching running job in its latest API response.

## 2b. Connect from another Mac

1. Install and open Cantrip on the second Mac.
2. Put both Macs on the same local network.
3. Select the second Mac's **Remote** tab, or press **Command+1**.
4. Paste the host's **Pairing token**.
5. Leave the optional HTTPS address blank for LAN-only use.
6. Click **Connect** and allow Local Network access if prompted.
7. Select or create a session in the remote view, then send a short question.

**Expected result:** the connection header shows **Local network** and the
Remote tab's status indicator becomes green while the host responds.
Remote sessions stay inside this view; they do not become local tabs on the
second Mac.

Remote sessions appear in an **expanded Tabs list on the left**, with **+**
for a new tab and per-row close/name/lock controls. Scroll vertically with a
trackpad, mouse wheel, or scrollbar to reach every tab. The list scrolls
independently of the conversation, keeps its place during background refreshes,
and brings selected or newly created tabs into view.

Each Mac Remote tab shows a pulsing brain while working, the host's current
activity, and any queued-message count. The selected tab's status also stays
visible near the message box while you scroll through older output. Idle tabs
show **Ready**, and interrupted tabs that can resume show **Paused**. Expand
the existing tool steps in the conversation for inputs, outputs, and results.
These are live activity indicators, not estimated completion percentages.
During a disconnect, activity animations stop and status is marked **Last
known** until the connection recovers. Reduce Motion disables the animations.

The main Cantrip session tabs stay **across the top**. Ordinary browser clients
also keep their horizontal tab strip with trackpad/mouse-wheel scrolling.
Update and reopen the host, then reload the Mac Remote view to get the sidebar
and progress indicators; no AgentGateway update is needed.

Use **Change server** to configure a different host.

## Rename and protect remote tabs

In the Mac Remote view or browser, click the **...** beside a session tab to
edit its name and lock. In AgentGateway, long-press a session tab or open its
**...** actions menu, then choose **Rename Tab**, **Lock Tab**, or **Unlock Tab**.
Names and locks belong to the Mac session and appear on all connected clients.

Locked sessions cannot be closed or reset, even by an older client with stale
state. The host rejects these requests with HTTP 409. Normal sending, Stop,
Resume, and queue removal still work. Unlock before closing or clearing.
Update and reopen the host to enable these controls; updated AgentGateway
checks the `supportsTabMetadata` capability before editing.

Authenticated session snapshots include `customTitle` (empty for automatic
naming), `isLocked`, and `supportsTabMetadata`. To edit, use
`POST /api/v1/sessions/{sessionID}/metadata` with `customTitle` (string),
`isLocked` (boolean), or both. Omitted fields are unchanged. Whitespace in
names is normalized; blank restores automatic naming, and names over 80
characters are rejected without applying any part of the update.

## Add access away from home

Use **Tailscale Serve**, not Funnel and not a router port-forward.
Serve makes the endpoint available within your tailnet, subject to its access
rules; Funnel would publish it to the internet.

1. Install and sign in to [Tailscale](https://tailscale.com/download) on the
   host and each client device. Ensure your tailnet rules allow access.
2. On the host, open Terminal and run `tailscale serve status` to inspect any
   existing Serve configuration before changing it.
3. If the root HTTPS endpoint is not already serving another app, run:

```sh
tailscale serve --bg http://127.0.0.1:8765
```

4. Replace `8765` if you changed Cantrip's **Port**. Follow any Tailscale
   instructions to enable HTTPS/Serve.
5. Copy the HTTPS origin printed by Tailscale, for example
   `https://your-mac.your-tailnet.ts.net`, into the client's optional Tailscale
   URL field. Use the origin without `/api`, a query string, or a token.
6. Save/connect again. On a phone, turn off Wi-Fi, leave Tailscale connected,
   and send a short prompt to confirm remote access.

If `tailscale` is not found, follow Tailscale's instructions for making its CLI
available. If the HTTPS root already hosts another service, do not overwrite
it; arrange a separate supported HTTPS origin/port first.

**Expected result:** native clients prefer the saved Tailscale HTTPS origin,
even on the same local network, and use paired LAN if Tailscale is unavailable.
Without a saved URL, they connect directly over LAN. HTTPS does not remove the
requirement for the pairing token.

### Automatic recovery and Tailscale-only mode

Automatic mode tries the saved Tailscale URL first and keeps it while it works.
It never probes or promotes LAN behind a healthy Tailscale connection, even
when Bonjour advertises the host. If Tailscale fails, reads can fall back to LAN;
independent read-only probes require two consecutive authenticated successes,
at least three seconds apart, before restoring Tailscale. They never hold up LAN
refreshes. Tailscale reads have a three-second total deadline, and failures back
off for 15 seconds.
LAN connection attempts and reads time out after two seconds, and failed LAN
routes back off for 30 seconds. Discovery changes do not clear these cooldowns.
If every route is cooling down, reads retry one route rather than waiting out
the whole cooldown. Late failures cannot displace newer successful requests.
Longer mutation and image-upload response deadlines remain in place.

The Mac Remote view switches upstream routes behind the same local bridge:
the selected session and unsent draft stay in the existing page. If no route
works, it reports the connection failure and retries reads as routes recover.
Web refreshes are coalesced so slow responses do not build a request backlog
or overwrite a newly selected session. Web reads have an eight-second deadline
that leaves time for the native bridge's HTTPS-to-LAN fallback.
Uncertain sends and other mutations are **not automatically replayed**. Check
the session before sending again; the host may have accepted the first request.

To bypass LAN, enable **Tailscale only (skip local network)** when pairing,
or use **Route > Tailscale only** in the Mac Remote header. AgentGateway has
the same toggle in Remote settings. A saved Tailscale URL is required; keep
Tailscale connected when using its HTTPS address. Choose **Automatic (Tailscale
first)** on the Mac, or turn off the toggle in AgentGateway, to allow
direct LAN as backup. LAN-only use remains supported without a saved URL.

For the browser client, connect the device to Tailscale, open the same HTTPS
origin, paste the pairing token, and click **Connect**. The browser saves its
token in that browser profile; use **Unpair** on shared devices. A browser
cannot connect directly to Cantrip's native LAN TLS service by opening the
Mac's IP address.

## Send a photo or screenshot from AgentGateway

**Requirements:** current versions of both apps and a host session that
advertises image support. Use a Claude, Copilot, or Codex backend on the Mac,
not Local Model. Updating only AgentGateway is not enough.

1. In AgentGateway, choose **Cantrip Remote** and select a session.
2. Tap the **+** (**Attach images or video**) beside the chat composer.
3. Choose **Photo Library**, **Choose Image File**, or **Paste Image**.
4. Wait for **Preparing attachment...** to finish.
5. Tap a thumbnail to view the full image, or its **x** to remove it.
6. Add a question if desired, then send. An image-only message is allowed.

**Expected result:** up to **four images per message** are sent over the
authenticated connection. AgentGateway converts/resizes them to JPEG and
removes location metadata before upload; visible private information in the
image is not redacted automatically.

The host accepts at most 1 MB per JPEG and 2048 pixels per side. Use the
picker's prepared images rather than manually encoding oversized uploads.
Image uploads cannot be combined with `!shell` or `/skill` commands.

If the picker says **Update Cantrip on your Mac to attach images**, update
**and relaunch** the host. If it says to choose a supported backend, do that
on the Mac, wait for any Local Model run to finish, and refresh the session.
The browser and desktop Remote web view do not currently have this image
picker.

Image drafts are kept per session when sending fails. For **Message not
confirmed**, check the host transcript before retrying: an interrupted
connection may mean the result was not received, not that the host never
accepted the message.

Uploaded images remain on the host in
`~/.cache/Cantrip/remote-attachments/` so queued work and follow-ups can read
them. They are not automatically deleted after the reply.

With both apps updated, AgentGateway shows sent and queued attachments as
tappable thumbnails rather than Mac file paths, including older uploads still
referenced by the open session. The full-screen viewer fits the entire uploaded
image; pinch or double-tap to zoom, drag to pan, and tap **Done** to return.
If the Mac is unreachable or a file was deleted, the image shows a retry state.
Older AgentGateway clients keep the original prompt text unchanged.

The pairing-authenticated, read-only
`GET /api/v1/sessions/{sessionID}/attachments/{uploadID}/image-{1...4}.jpg`
returns the uploaded JPEG as base64 JSON (`data`); append `/thumbnail` for a
320-pixel preview. Only stored upload IDs referenced by that public session's
user messages or queue are available, never arbitrary filesystem paths.
Image reads and downsampling run off the main actor. AgentGateway keeps a
bounded in-memory cache, clears it on pairing changes, and uses the same
Tailscale-first/LAN-fallback routing as other read-only requests.

## Generated image previews in AgentGateway

With both apps updated and the Mac host reopened, screenshots and generated
images can appear **inline in assistant replies**, in their original Markdown
position. Tap a preview to open the full-screen viewer, pinch or double-tap to
zoom, and tap **Done** to return. Loading failures show a retry action.

Save PNG or JPEG output directly under `~/.cache/Cantrip/`, then include a
standalone Markdown image in the assistant's reply:

```markdown
![Landscape preview](~/.cache/Cantrip/landscape-preview.png)
```

Absolute paths and local `file:` URLs also work; use `<...>` around paths
containing spaces or parentheses. Up to eight distinct images are presented per
message. Code examples, ordinary links, remote URLs, subdirectories (including
uploaded attachments), and files outside this output folder do not authorize
preview reads. Private Local keeps its existing text-only output behavior.

The host preserves original transcript text and adds `displayText` with
`cantrip-preview://image/previews/{messageID}/{hash}.jpg` references plus `images`
metadata (`id`, `altText`). The pairing-authenticated read-only route
`GET /api/v1/sessions/{sessionID}/previews/{messageID}/{hash}.jpg` returns
base64 JPEG JSON (`data`); append `/thumbnail` for a 960-pixel inline preview.
Each request requires that assistant message to remain in the same public
session, including when serving a cached image. No client-supplied file path is
accepted. Symlinks, hard links, non-images and oversized sources are rejected.

Image reads and conversion run off the main actor. Source files are limited to
30 MiB, 64 million pixels and 16,384 pixels per side. Delivery is re-encoded
without source metadata, at most 4096 pixels per side and 4 MiB. The first
successful read stores an owner-only copy in
`~/.cache/Cantrip/remote-previews/{sessionID}/{messageID}/`; it survives source
cleanup and host restarts. These cached copies are not automatically deleted.
Previously linked screenshots work if their original files still exist when
first loaded. Neither a public upload nor a temporary Safari gallery is needed.
This adds native AgentGateway rendering; the browser/Mac Remote web transcript
continues using its existing text rendering.

## Send a video for analysis from AgentGateway

With both apps updated and the host reopened, use **+ > Video Library** or
**Choose Video File**. Attach one standard MOV/MP4, up to **100 MB and five
minutes**, instead of images. Preview it locally, add a question or send it
alone, and use the preparation/upload progress and Cancel controls as needed.
Videos need a Claude, Copilot, or Codex backend and cannot be sent with shell
or slash commands.

Cantrip retains the exact original, including audio and metadata, under
`~/.cache/Cantrip/remote-videos/{sessionID}/{uploadID}/`. SHA256 verification
and AVFoundation decoding precede prompt delivery. Four oriented JPEG frames
and their actual timestamps provide a sparse visual overview; the agent
receives the original path for deeper tool-based analysis. This does **not**
pretend to watch every frame or automatically transcribe audio. Sent/queued
messages include the description and existing tappable image thumbnails.

Session snapshots advertise `supportsVideoAttachments`. Paired
`GET /api/v1/sessions/{id}/videos/{uploadID}` reads the confirmed upload offset.
`PUT` to the same path uploads at most 1 MiB of binary data, with query metadata
`offset`, `totalBytes`, `format`, `name`, and `sha256`. Repeated offsets must
contain identical bytes; holes, conflicting metadata, and oversized chunks
are rejected. The manifest acknowledges only synchronized bytes, allowing
safe retry/failover and recovery across a host restart.
`POST .../videos/{uploadID}/prepare` verifies the original and creates the
durable preview once. These calls never send a prompt. The final one-shot
`POST .../messages` includes `videoID`, `text`, and `mode`; normal queue,
Auto, redirect, and injection behavior applies. Private/other-session uploads
are not accessible.

Video transfers use an independent route reader because their operations are
idempotent; they do not hold the polling/mutation gate. Final prompt mutations
are never blindly replayed. Upload writes/preparation allow 60 seconds per
request; existing lightweight connection budgets are unchanged.
Mobile drafts remain available after a failure/cancel while the app is alive.
Pausing/backgrounding cancels an unfinished upload; no background-delivery
promise or persistent mobile outbox is implied.

Sent originals and frames remain for queued/recovered work. Unsubmitted
uploads reserve at most 500 MB; abandoned uploads older than 24 hours are
reclaimed when starting a new upload. These limits do not truncate videos.

## Understand what is available remotely

| Situation | Behavior |
|---|---|
| Host screen locked, user still signed in, Mac awake | Remote can stay available; GUI-dependent tasks may need the Mac unlocked |
| Host asleep, logged out, powered off, or waiting at pre-login/FileVault | Remote is unavailable |
| Private session | Not exposed to Remote clients |
| Local screenshot, selection, or file staged in Cantrip | Not automatically consumed by a Remote prompt |
| Host calendar/location | Not automatically added to a Remote prompt |
| Existing session messages or enabled memory | Can still provide context; Remote is not a clean-room conversation |

Remote access is not a separate low-privilege account. An action-enabled host
agent can still access data through its tools when instructed.

## Revoke access or disconnect

To revoke **all existing pairings**, click **Regenerate** beside the token on
the host. Pair clients again with the new token.

To stop accepting Remote requests, turn off **Remote control daemon**.
To forget one client's saved credentials, use **Clear Remote Connection** in
AgentGateway or **Unpair** in the web client. Forgetting a client does not
rotate the host token.

For failures, follow [Remote connection troubleshooting](updating-and-troubleshooting.md#remote-will-not-connect).
