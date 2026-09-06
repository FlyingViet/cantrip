[User Guide](README.md) / Files and screen context

# Ask about a file, screenshot, or selected text

**Platform: macOS.** These steps use local Cantrip. For iPhone/iPad uploads,
see [AgentGateway attachments](remote-control.md#send-a-photo-or-screenshot-from-agentgateway).
Windows currently supports [screen capture](windows.md#capture-your-screen),
not clipboard/drop file attachments.

Use **Claude Code**, **Copilot**, or **Codex** for these workflows. Local Model
does not receive staged attachments or screen images. A CLI must also have a
working image/file tool and sufficient permissions to read the attachment.

## Attach a file or image

1. Open the Cantrip session you want to use.
2. Drag a file from Finder onto the panel. Alternatively, copy an image or
   file in another app and press **Command+V** in Cantrip.
3. Confirm an attachment chip appears. Remove the chip with its **x** if it
   is the wrong file.
4. Add a question, such as `Explain the error in this screenshot` or
   `Summarize this document in five bullets`.
5. Press **Return**.

**Expected result:** the attachment is included with the next question and
the staged chip clears. Attach it again if you need to resend it. For an
image-only submission from a phone, use AgentGateway instead.

Cantrip supplies file paths to the CLI's tools. Keep the file at that path
while work is queued or running; a file preview does not guarantee that every
backend can interpret every format.

## Capture a screenshot without sharing every display

1. On Mac, press **Control+Shift+Command+4**.
2. Drag over the region you want to capture. This copies that region to
   the clipboard.
3. Open Cantrip with **Option+Space**, then press **Command+V**.
4. Confirm the attachment chip, type your question, and send.

Use this approach when you only want to share one error or a small part of an
app. Crop or redact sensitive information before attaching.

## Let a question see your displays

1. Bring the relevant app or window to the front.
2. Open Cantrip and click **Screen context**, the small window icon.
3. If needed, open **System Settings > Privacy & Security** and enable Cantrip
   under **Screen Recording** or **Screen & System Audio Recording**, depending
   on your macOS version. Quit and reopen Cantrip when macOS requires it.
4. Hide and reopen Cantrip after arranging the windows you want it to see.
5. Ask a question such as `What does the error in this window mean?`
6. Turn **Screen context** off when finished.

**Expected result:** the agent can inspect screenshots taken before the
launcher covers your apps. This can include **all connected displays**.
Screen context is a persistent toggle, not a one-shot attachment; it stays
enabled until you turn it off.

If the screen changes after the capture, hide and reopen the panel for a
fresh capture rather than asking about an old image.

## Ask about selected text

1. Select text in the app you are using.
2. Press **Option+Shift+Space**.
3. Confirm Cantrip shows the selected text and source app.
4. Type what to do with it, such as `Rewrite this more clearly`, and send.

Selection capture may require **Accessibility** permission in
**System Settings > Privacy & Security**. If no selection appears, copy the
text and paste it into the question instead.

## Get visual instructions for an app

1. Enable screen context and make the relevant controls visible.
2. Open Cantrip and ask a specific question, such as
   `Show me where to change the export format in this window.`
3. Follow any numbered on-screen tooltips together with the written steps.

The AI must inspect the correct screenshot and identify the controls; tooltips
are not guaranteed for every app or response. If the window is wrong or a
control is hidden, expose it and capture again. **Escape** dismisses overlays.

For what is retained or sent to providers, read
[permissions, privacy, and memory](privacy-and-memory.md).
