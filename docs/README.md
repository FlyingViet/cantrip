# Cantrip User Guide

Cantrip is a keyboard-first launcher that can open apps, answer questions, and
use an AI agent to work on your computer. Start with a question; enable actions
only when you want the agent to make changes.

**New here?** Follow [Install and start on Mac](getting-started-macos.md) or
[Install and start on Windows](windows.md). You only need one AI backend.

## What would you like to do?

| I want to... | Open this guide |
|---|---|
| Install Cantrip and ask my first question | [Mac setup](getting-started-macos.md) / [Windows setup](windows.md) |
| Use Claude, Copilot, Codex, or my own model | [Choose and configure an AI backend](backends.md) |
| Open apps, find files, run commands, or use voice | [Everyday tasks](everyday-tasks.md) |
| Send a question or pipe a log from Terminal | [Cantrip CLI](everyday-tasks.md#ask-cantrip-from-terminal) |
| Ask about a screenshot, document, or selected text | [Files and screen context](files-and-screen-context.md) |
| Keep projects separate, resume work, or compare models | [Sessions and council mode](sessions-and-council.md) |
| Control my Mac from AgentGateway or another Mac | [Remote control](remote-control.md) |
| Send a photo from my iPhone or iPad | [AgentGateway image attachments](remote-control.md#send-a-photo-or-screenshot-from-agentgateway) |
| Decide what Cantrip can do, see, and remember | [Permissions, privacy, and memory](privacy-and-memory.md) |
| Install a dashboard or add my own command | [Extensions and skills](extensions-and-skills.md) |
| Update Cantrip or fix a problem | [Updates and troubleshooting](updating-and-troubleshooting.md) |
| Find a keyboard shortcut | [Keyboard reference](keyboard-shortcuts.md) |

## A few terms

| Term | Meaning |
|---|---|
| Backend | The AI service or command-line app Cantrip uses, such as Claude Code or Copilot. |
| Model | The particular AI selected within a backend. Availability depends on your account or local server. |
| Session | A conversation tab with its own work and working directory on macOS. |
| Working directory | The folder where a session's commands start, usually your project folder. It is not a security boundary. |
| Host | The Mac running Cantrip and doing the work when you use Remote control. |
| Pairing token | A secret used to connect a remote client to your host. Treat it like a password. |
| Memory vault | A folder of readable Markdown notes used for context across conversations. |

## Which platform does a guide cover?

Unless marked otherwise, these guides describe the **macOS app**. Windows
supports the core launcher, cloud CLI backends, screen capture, and plugins,
but does not yet have all Mac features. The [Windows guide](windows.md#what-is-and-is-not-available)
lists the important differences.

Instructions describe the source on the repository's `main` branch. If a
control is missing in your installed version, start with
[updating Cantrip](updating-and-troubleshooting.md). AI model availability,
provider limits, and operating-system permission names can change independently
of Cantrip.

For implementation details rather than user instructions, see the
[repository overview](../README.md), [plugin reference](../PLUGINS.md), and
[Windows parity checklist](../windows/PARITY.md).
