[User Guide](README.md) / AI backends

# Choose and configure an AI backend

Use one backend you already have access to. Cantrip launches the CLI for
Claude Code, Copilot, or Codex; **signing in to a provider's website alone does
not sign in its CLI**.

| Choice | What you need |
|---|---|
| Claude Code | Installed `claude` CLI and an authorized account |
| Copilot | Installed `copilot` CLI and an account with Copilot CLI access; macOS also needs Node.js and the CLI's bundled SDK/runtime |
| Codex | Installed `codex` CLI and an authorized account |
| Local Model (Mac only) | A running OpenAI-compatible server and its exact model ID |

## Install and sign in to a cloud backend

The npm installation options below require [Node.js and npm](https://nodejs.org/).
Use a Node.js version supported by the CLI you choose. Run **one** matching
pair of commands in Terminal on Mac, or in your backend's supported shell on
Windows:

| Backend | Install | Open and sign in |
|---|---|---|
| Claude Code | `npm install -g @anthropic-ai/claude-code` | `claude` |
| Copilot | `npm install -g @github/copilot` | `copilot` |
| Codex | `npm install -g @openai/codex` | `codex` |

1. Complete that CLI's sign-in prompts.
2. Ask it a short question to confirm your account works.
3. Open Cantrip's **gear**, then select the matching **Backend**.
4. Start with the default **Model** and **Effort**, where those controls are
   available.
5. Send a new question in Cantrip.

Model names in examples are not a promise of access. If a model is rejected,
return to the default or choose one your CLI/account supports. An option
visible in a picker may still require provider entitlement.

On Mac, the backend's **path (blank = auto)** field normally stays blank.
If automatic detection fails, run `command -v claude`, `command -v copilot`,
or `command -v codex` in Terminal and paste the returned executable path into
the matching field.

On macOS, local Copilot runs through a persistent native SDK session, not a
one-shot prompt process. Use a recent CLI with its bundled SDK and runtime
(exercised with 1.0.83), and ensure `node` is available in your login shell.
Cantrip resolves both from the configured CLI installation/version; it does
not substitute another cached version when a custom path is invalid.
This enables [live context injection](sessions-and-council.md#send-instructions-while-the-agent-is-busy).
Without action permissions the native adapter exposes only read/search tools;
read-only council advisors receive no tools. Permission requests that cannot
be approved by the current action policy are denied rather than left hanging.

## Choose a model, effort, or context window

1. Open **Settings** and select the backend first.
2. Choose a **Model** or enter an ID in the backend's model field.
3. If **Effort** is offered, leave it at **Default** until you have a reason
   to change it. Higher effort can take longer and consume more usage.
4. For Copilot, use **Context window** only with a model/account that supports
   the selected tier. A larger context can increase usage.
5. Apply the choice to your next request; changing a picker does not rewrite
   an answer already being generated.

On macOS, backend/model settings are shared app settings, not independent
saved selections for every tab. Working directories and conversations are
per-session.

## Connect a local model

**Mac only.** Cantrip does not install or start the model server for you.
Ollama, llama.cpp, and vLLM are examples of servers that can expose an
OpenAI-compatible API.

1. Start your server using its own setup instructions and load a model.
2. Find the server's API base URL, including `/v1`, and its exact model ID.
3. In Cantrip Settings, select **Local Model**.
4. Enter **Base URL**, **Model**, and **API key (optional)** if the server
   requires one.
5. Send `Reply with one short sentence so I can confirm this connection.`

For example, an Ollama server on the same Mac commonly uses
`http://127.0.0.1:11434/v1`. Other servers may use a different port.
For that example, this command lists the model IDs the server exposes:

```sh
curl --fail http://127.0.0.1:11434/v1/models
```

Use an `id` from the response; do not assume the default name `hermes` matches
your server. For a password-protected server, use its documented authentication.
Do not expose an unauthenticated model server to the public internet.

**Expected result:** the model responds through Cantrip. Tool use also requires
a model with compatible tool-calling support and **Act on my behalf** enabled.
The current Local Model backend does not receive Cantrip's staged file/image
attachments or screen captures; use a supported CLI backend for those tasks.

## Let the agent take actions

1. Select the intended project with the toolbar's **folder** button.
2. Review [what action permissions allow](privacy-and-memory.md#let-an-agent-make-changes).
3. Enable **Act on my behalf** only if you want unattended commands and edits.
4. Give a bounded request, such as `In this project, update the README to
   explain the setup command. Do not change application code.`
5. Review the output and the **Progress** sidebar.

An action-enabled agent can work outside its starting directory. The selected
folder is a convenience, not a sandbox.

## Do not confuse the two Remote features

**Cantrip's Remote tab** connects to another Mac's Cantrip sessions; follow
[Remote control](remote-control.md).

**Copilot Remote** in the backend picker is an advanced connection to a
Copilot ACP server. It does not connect to a Cantrip host or use a Cantrip
pairing token. Ordinary Copilot users should choose **Copilot**, not
**Copilot Remote**.
