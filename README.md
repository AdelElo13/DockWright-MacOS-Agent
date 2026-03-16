# Dockwright

**A native macOS agent that sees, acts, and remembers.**

Dockwright is a fully native Swift macOS AI assistant that combines the best of OpenClaw's reliability, Manus's autonomy, and Jarvis's sensory awareness — all in one local-first app.

---

## Features

### Core
- **Streaming LLM chat** — Claude, GPT-4o, Ollama (local models)
- **OAuth sign-in** — One-click Claude & OpenAI auth (PKCE), or paste API key
- **Tool calling** — Shell, files, web search, clipboard, system control
- **Conversation threads** — Full history with SQLite + FTS5 search

### Scheduling & Reminders
- **Cron engine** — Full 5-field cron expressions with timezone support
- **Natural language reminders** — "Remind me in 2 minutes to drink water"
- **macOS notifications** — Native delivery via UNUserNotificationCenter
- **Restart catch-up** — Missed jobs execute on next launch
- **Heartbeat** — 30-minute health checks with smart deduplication

### Sensory Awareness
- **Screen capture + OCR** — 15-second ambient loop with change detection
- **Browser tab watching** — Safari, Chrome, Firefox, Edge, Arc, Brave
- **Active document detection** — Knows which file you're editing in Xcode/VS Code
- **World model** — Unified sensory context injected into every LLM call

### Voice
- **Speech-to-text** — Apple SFSpeechRecognizer with silence detection
- **Text-to-speech** — System TTS with streaming sentence boundaries
- **Wake word** — "Hey Dockwright" via SFSpeechRecognizer
- **Hands-free mode** — Continuous listen → transcribe → respond → speak loop

### Agent Mode
- **Autonomous execution** — Give a goal, Dockwright plans and executes steps
- **Self-correction** — Failed steps are analyzed and retried differently
- **Progress reporting** — Step-by-step UI updates
- **20-step safety limit** — Cancellable at any point

### Apple Integration
- **Apple Reminders** — Create, complete, list, delete via EventKit
- **Apple Notes** — Create, search, read via AppleScript
- **Menu bar** — Quick access from anywhere
- **Global hotkey** — Cmd+Shift+Space to summon

### Vision & Files
- **Image analysis** — Drag & drop or paste screenshots (Claude Vision API)
- **File drop** — Drop code files into chat for instant analysis
- **Clipboard intelligence** — Auto-detect code, URLs, file paths
- **Export** — Save conversations as Markdown or PDF

### Skills
- **Markdown-based** — Drop a `.md` file in `~/.dockwright/skills/` to teach Dockwright new abilities
- **Built-in skills** — Code review, git workflow, system diagnostics, file organizer
- **No code required** — Skills are natural language instructions, not plugins

---

## Quick Start

1. Open `Dockwright.xcodeproj` in Xcode
2. Cmd+R to build and run
3. Sign in with Claude (OAuth) or paste an API key
4. Start chatting — try "What's running on my system?" or "Remind me in 1 minute to stretch"

### Requirements
- macOS 14.0+
- Xcode 16+
- An Anthropic, OpenAI, or Ollama API key (or use OAuth)

---

## Architecture

```
Dockwright/
├── App/           — Entry point, global state
├── Core/
│   ├── Agent/     — Autonomous multi-step execution
│   ├── Channels/  — Notification delivery
│   ├── Heartbeat/ — Proactive health checks
│   ├── LLM/       — Multi-provider streaming (Anthropic, OpenAI, Ollama)
│   ├── Memory/    — SQLite + FTS5 conversations & facts
│   ├── Scheduler/ — Cron engine, reminders, atomic JSON store
│   ├── Sensory/   — Screen capture, OCR, browser tabs, world model
│   ├── Skills/    — Markdown skill loader
│   ├── Tools/     — 12 tools (shell, file, web, vision, clipboard, system, ...)
│   └── Voice/     — STT, TTS, wake word, session coordinator
├── UI/            — SwiftUI views (chat, sidebar, settings, scheduler)
└── Utilities/     — Keychain, SQLite, OAuth, logging
```

**54 Swift files** · **11,800+ lines** · **Zero warnings**

---

## What Makes Dockwright Different

| | Dockwright | OpenClaw | Manus | Open Interpreter |
|---|---|---|---|---|
| Native macOS | ✅ Swift | ❌ TypeScript | ❌ Cloud | ❌ Python |
| Runs locally | ✅ | ✅ | ❌ | ✅ |
| Screen awareness | ✅ | ❌ | ❌ | Partial |
| Voice | ✅ | ✅ | ❌ | ❌ |
| Cron scheduling | ✅ | ✅ | ❌ | ❌ |
| Agent mode | ✅ | ❌ | ✅ | ❌ |
| Apple Reminders | ✅ | ✅ | ❌ | ❌ |
| OAuth (no API key needed) | ✅ | ❌ | N/A | ❌ |
| Image analysis | ✅ | ❌ | ✅ | ✅ |
| File watching | ✅ | ❌ | ❌ | ❌ |

---

## License

Private — all rights reserved.
