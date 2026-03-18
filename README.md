<p align="center">
  <img src="Dockwright/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" height="128" alt="Dockwright icon">
</p>

<h1 align="center">Dockwright</h1>

<p align="center">
  <strong>Your Mac. Your AI. No cloud required.</strong>
</p>

<p align="center">
  A native macOS AI assistant that sees your screen, hears your voice,<br>
  runs your tools, and remembers what matters — built entirely in Swift.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/lines-30K-0891B2?style=flat-square" alt="30K lines">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  <a href="https://x.com/dockwrightapp"><img src="https://img.shields.io/badge/X-@dockwrightapp-000000?style=flat-square&logo=x&logoColor=white" alt="X"></a>
  <a href="https://www.tiktok.com/@dockwright"><img src="https://img.shields.io/badge/TikTok-@dockwright-000000?style=flat-square&logo=tiktok&logoColor=white" alt="TikTok"></a>
  <a href="https://discord.com/channels/@me"><img src="https://img.shields.io/badge/Discord-Join-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord"></a>
  <a href="https://dockwright.com"><img src="https://img.shields.io/badge/Web-dockwright.com-0891B2?style=flat-square&logo=safari&logoColor=white" alt="Website"></a>
</p>

---

## What is Dockwright?

Dockwright is a fully native macOS assistant — not a wrapper around a web app. It connects directly to Claude, OpenAI, Gemini, Grok, xAI, or local models via Ollama, and gives them real access to your system: files, shell, screen, browser, calendar, contacts, reminders, and more.

It doesn't just chat. It acts.

---

## Capabilities

### Conversation
- Streaming responses with full Markdown rendering
- Multi-provider support — Claude, OpenAI, Gemini, Grok, xAI, DeepSeek, Mistral, Kimi, Ollama
- OAuth sign-in (Claude, OpenAI) or API key
- Conversation history with full-text search
- Image analysis — drag, paste, or screenshot

### Tools
Shell commands, file operations, web search, clipboard, system info, Apple Reminders, Apple Notes, Calendar, Contacts, iMessage, Music/Spotify control, Finder operations, and more — 30 tools the AI can call autonomously.

### UI Automation (ProcessSymbiosis)
Direct control of any macOS app via the Accessibility API. Click buttons, type text, press keyboard shortcuts, read UI elements — no pixel-guessing. Live AXObserver event stream monitors the frontmost app in real time, building a semantic model the AI can act on instantly.

### Voice
Hands-free operation with Apple Speech Recognition. Tap the mic, speak naturally, get a spoken response. Silence detection, continuous mode, and session coordination to prevent audio conflicts.

### Screen Awareness
A 15-second ambient loop captures your screen, runs OCR, and feeds context to the AI. It knows which app is active, what you're reading, and which browser tabs are open — across Safari, Chrome, Firefox, Edge, Arc, and Brave.

### iMessage
Read conversations, search messages, and send texts — directly from the AI. Reads the native Messages database and sends via AppleScript.

### Scheduling
Full cron engine with natural language. "Remind me in 2 minutes to stretch" just works. Recurring jobs, one-shot reminders, missed-job catch-up on relaunch, and native macOS notifications.

### Agent Mode
Give Dockwright a goal and it will plan, execute, self-correct, and report progress — up to 50 tool calls per task with full cancellation support. Token budgets auto-scale per model (800K for Opus, 160K for Sonnet).

### Memory
Auto-extracts facts from conversations and recalls them when relevant. Ranked retrieval (importance × relevance), automatic consolidation of stale/duplicate facts, and a **PoisonGuard** that blocks prompt injection attempts and credential leaks from being stored. Remembers tool failures and adapts — never bans a tool, just learns to call it smarter. SQLite + FTS5 backed.

### Skills
Drop a Markdown file in `~/.dockwright/skills/` and Dockwright learns new abilities. No code required. Comes with **20 community skills** pre-bundled — web search, image generation, security scanning, Excel/Word creation, and more. Activate them from the Skill Store.

### Profile
Set your name, bio, avatar, and shipping address in Settings → Profile. Dockwright uses your name in conversations, shows your picture in chat, and auto-fills checkout forms when shopping on your behalf. You can also rename your assistant — call it whatever you want.

### Menu Bar Panel
Floating chat accessible from the macOS menu bar. Pin it to stay on top while Dockwright works in Safari or other apps. Resize between compact and expanded. Same conversation, same tools — just a different window.

### Integrations
- Telegram bot — chat with Dockwright from your phone
- WhatsApp Business — two-way messaging via Meta Cloud API
- Discord — webhook notifications
- A2A server — agent-to-agent protocol on port 8766
- MCP server — Model Context Protocol on port 8767
- Siri Shortcuts — 9 intents for Spotlight and Siri
- Menu bar — always one click away
- Global hotkey — Cmd+Shift+Space

---

## Getting Started

1. Open **Dockwright.xcodeproj** in Xcode 16+
2. **Cmd+R** to build and run
3. Sign in with Claude or paste an API key
4. Start with: *"What's on my screen?"* or *"Remind me in 1 minute to stretch"*

### Requirements

| | |
|---|---|
| **OS** | macOS 14.0 Sonoma or later |
| **Xcode** | 16.0 or later |
| **AI Provider** | Anthropic, OpenAI, Google, xAI, DeepSeek, Mistral, Kimi, or Ollama |
| **Dependencies** | None — pure Apple frameworks + system tools auto-installed via Homebrew when needed |

---

## Architecture

```
Dockwright/
├── App/           Entry point, global state, permissions
├── Core/
│   ├── Agent/     Autonomous multi-step execution
│   ├── Channels/  Notification delivery
│   ├── Heartbeat/ Proactive health checks
│   ├── LLM/       Multi-provider streaming
│   ├── Memory/    SQLite + FTS5, auto-formation, error memory
│   ├── Scheduler/ Cron engine, reminders
│   ├── Sensory/   Screen capture, OCR, browser tabs, world model, ProcessSymbiosis, AX control
│   ├── Skills/    Markdown skill loader
│   ├── Tools/     30 tools (incl. UI automation, iMessage, Calendar, Music)
│   └── Voice/     STT, TTS, wake word
├── UI/            SwiftUI (chat, sidebar, settings, onboarding)
└── Utilities/     Keychain, SQLite, OAuth, logging
```

**95+ Swift files** · **30,000+ lines** · **Zero external dependencies**

---

## Privacy

Dockwright runs locally on your Mac. Screen captures, voice recordings, and memory stay on disk in `~/.dockwright/`. API calls go directly to your chosen provider — nothing passes through third-party servers.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT License](LICENSE) — free to use, modify, and distribute.
