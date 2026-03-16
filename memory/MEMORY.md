# Dockwright Memory

## Project Origin
- Created 2026-03-16 by Adel
- Combines best of JarvisMac (voice, sensory, UI, multi-LLM) and OpenClaw (scheduling, browser, cron)
- Goal: better than both, everything actually working and tested

## Build Rules (from user)
- NEVER claim tests pass without showing actual output proof
- User lost trust after false "all green" claims in JarvisMac project
- Build after every file group — catch errors immediately
- No stubs, no TODOs — everything must be real implementation
- User speaks Dutch, app should handle both Dutch and English

## Xcode Project
- Path: /Users/a/Dockwright
- Bundle ID: com.Aatje.Dockwright.Dockwright
- Team: A3W973JZ49
- App Sandbox: OFF
- Hardened Runtime: ON
- Xcode 26.2, uses PBXFileSystemSynchronizedRootGroup (auto-detects files)
- SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (Swift 6 strict concurrency)

## Reference Sources
- JarvisMac: /Users/a/Open-Jarvis/JarvisMac/JarvisMac/
- Jarvis Python backend: /Users/a/jarvis_assistant_v2/
- OpenClaw app: /Volumes/OpenClaw/OpenClaw.app/ (DMG mounted)
- OpenClaw config: ~/.openclaw/

## Key Decisions
- Phase 1-3: ZERO external SPM dependencies (Apple frameworks only)
- Phase 4: Voice uses Apple Speech + AVFoundation (no Whisper, no ONNX initially)
- TTS starts with AVSpeechSynthesizer, Kokoro upgrade later
- Cron: full 5-field parser (from Python jarvis), not interval-only (Swift jarvis was limited)
- Data stored in ~/.dockwright/ (not Application Support — simpler)

## Data Locations
- Conversations: ~/.dockwright/conversations/*.json
- Cron jobs: ~/.dockwright/cron_jobs.json
- Memory DB: ~/.dockwright/memory.db
- Logs: ~/.dockwright/logs/

## API Keys (Keychain)
- anthropic_api_key
- openai_api_key
- gemini_api_key
- Service name: com.Aatje.Dockwright

## Build Phases
1. Foundation — chat works with streaming + tools ✅
2. Scheduling — cron + reminders + notifications
3. Sensory — screen capture + OCR + browser tabs + WorldModel
4. Voice — STT + TTS + wake word
5. Polish — multi-LLM + memory + menu bar + install script
