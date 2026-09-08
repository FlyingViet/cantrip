[User Guide](README.md) / Remote control

# Control Cantrip from another device

Remote control uses the **same live sessions on your Mac**. AgentGateway is
an iPhone/iPad client; another Mac can use Cantrip's **Remote** tab. A browser
can use the host's web client through Tailscale Serve.

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

The token authorizes access to non-private sessions and their controls.
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
2. Tap **Attach images** beside the chat composer.
3. Choose **Photo Library**, **Choose Image File**, or **Paste Image**.
4. Wait for **Preparing images...** to finish.
5. Review the previews. Tap an image's **x** to remove it.
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
