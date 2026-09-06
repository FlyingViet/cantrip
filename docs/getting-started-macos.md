[User Guide](README.md) / Mac setup

# Install and start on Mac

**You need:** macOS 14 or later, Xcode Command Line Tools, and one working AI
backend. Cantrip itself does not include a cloud subscription or a local model.

## 1. Install the Apple command-line tools

Open **Terminal** and run:

```sh
xcode-select -p
```

If this prints a developer-tools path, continue. If it reports that the tools
are missing, run the following and finish Apple's installer before continuing:

```sh
xcode-select --install
```

## 2. Set up one AI backend

Follow [backend setup](backends.md#install-and-sign-in-to-a-cloud-backend).
For a cloud backend, open its CLI in Terminal and finish signing in.
For a local model, start an OpenAI-compatible server and use
[the local-model instructions](backends.md#connect-a-local-model).

**Expected result:** your chosen backend can answer a simple question outside
Cantrip. You do not need to install all the backends.

## 3. Install Cantrip

Run these commands in Terminal:

```sh
mkdir -p ~/Coding
git clone https://github.com/FlyingViet/cantrip.git ~/Coding/Cantrip
cd ~/Coding/Cantrip
./install.sh
```

If that folder already contains your Cantrip checkout, do not clone over it;
use [the update instructions](updating-and-troubleshooting.md#update-on-mac).

The installer builds and signs `Cantrip.app` in the checkout, installs the
`cantrip` terminal command, and opens the app. A signing-certificate password
dialog may appear. Keep this folder: the app's update and rebuild commands use
it.

**Expected result:** a Cantrip sparkle icon appears in the macOS menu bar.

## 4. Choose your backend and review sharing

1. Press **Option+Space** to open Cantrip.
2. Click the **gear** to open Settings.
3. Choose your installed **Backend**. Leave **Model** at its default initially,
   or enter the model ID required by your local server.
4. Keep **Act on my behalf** off for your first question. For Claude, leave
   **Permissions** at **Safe**; for Copilot, also leave **Allow all tools** off.
5. Review **Memory vault**, **Search my documents' contents as context**,
   **Share my calendar as context**, and **Share my location as context**.
   These are enabled by default; turn off anything you do not want included.
   Calendar and location also require macOS permission.

You can decline optional permissions and still use text chat. See
[permissions and privacy](privacy-and-memory.md) before sharing sensitive data.

## 5. Ask your first question

1. Type `Explain what a working directory is in two sentences.`
2. Press **Return**.
3. Wait for the answer to appear in the panel.

If an app suggestion is selected instead, **Command+Return** sends your text
to the AI. While an AI run is already active, that same shortcut interrupts
and redirects it.

**Expected result:** the selected backend's answer streams into Cantrip. If
you see a sign-in or missing-command error, use
[backend troubleshooting](updating-and-troubleshooting.md#the-backend-is-missing-or-not-authenticated).

## 6. Make it available after login

Open Settings and enable **Launch at login**. This starts Cantrip after you
sign in to macOS, not at the FileVault or pre-login screen.

To open it manually later:

```sh
open ~/Coding/Cantrip/Cantrip.app
```

Continue with [everyday tasks](everyday-tasks.md) or
[connect AgentGateway](remote-control.md).
