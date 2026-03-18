# Dockwright — Autonomous Build Blueprint

> **You are building Dockwright**: a macOS AI assistant with voice, sensory awareness, scheduling, browser automation, and UI control. Everything in Swift. Everything working. No stubs.

## CRITICAL RULES

1. **NEVER claim something works without proving it.** Show actual build output, test output, or runtime proof.
2. **Build after EVERY file group.** Run `xcodebuild` after creating each logical group of files to catch errors immediately. Do not write 20 files then build.
3. **No stubs.** Every function must have real implementation. If you write `// TODO` you have failed.
4. **Swift 6 concurrency.** This project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. All non-UI types need explicit `nonisolated` or `@unchecked Sendable`. Use `sending` where needed.
5. **Test each phase.** After each phase builds, write a quick verification (print test, unit test, or runtime check).
6. **Read existing code first.** Read actual files before reimplementing — don't guess.
7. **Xcode auto-detects files.** This project uses `PBXFileSystemSynchronizedRootGroup` — just create `.swift` files in the right folders and Xcode picks them up. Do NOT edit `project.pbxproj` for source files.
8. **Bundle ID:** `com.Aatje.Dockwright.Dockwright`
9. **Deployment target:** macOS 14.0+ (change from 26.2 in pbxproj: `MACOSX_DEPLOYMENT_TARGET = 14.0`)
10. **SPM packages needed** (must add via pbxproj or Package.swift):
    - None initially.

## BUILD COMMAND

```bash
cd /Users/a/Dockwright && xcodebuild -project Dockwright.xcodeproj -scheme Dockwright -configuration Debug build 2>&1 | tail -30
```

Always check exit code. `** BUILD SUCCEEDED **` or fix errors before proceeding.

---

## ARCHITECTURE OVERVIEW

```
Dockwright/
├── App/
│   ├── DockwrightApp.swift        # @main, WindowGroup, MenuBarExtra, global hotkey
│   └── AppState.swift             # @Observable central state (conversations, settings, etc.)
│
├── Core/
│   ├── LLM/
│   │   ├── LLMService.swift       # Multi-provider streaming API calls
│   │   ├── LLMModels.swift        # LLMMessage, LLMResponse, ToolCall, StreamChunk
│   │   └── TokenCounter.swift     # Usage tracking + cost display
│   │
│   ├── Tools/
│   │   ├── ToolRegistry.swift     # Tool catalog + JSON schema definitions
│   │   ├── ToolExecutor.swift     # Execute tools, return results, feed back to LLM
│   │   ├── ShellTool.swift        # Run shell commands (Process + stdout/stderr/exit)
│   │   ├── FileTool.swift         # Read/write/list/search files
│   │   └── WebSearchTool.swift    # DuckDuckGo or similar web search
│   │
│   ├── Scheduler/
│   │   ├── CronEngine.swift       # 5-field cron expression parser + timer loop
│   │   ├── CronJob.swift          # Job model (id, name, schedule, action, enabled, etc.)
│   │   ├── CronStore.swift        # JSON file persistence (~/.dockwright/cron_jobs.json)
│   │   ├── CronRunner.swift       # Execute due jobs + delivery via channels
│   │   ├── ReminderService.swift  # "over 2 min hoi" → one-shot scheduled job
│   │   └── CronTool.swift         # LLM tool: create_reminder, create_cron, list_jobs, delete_job
│   │
│   ├── Memory/
│   │   ├── MemoryStore.swift      # SQLite + FTS5 for facts + conversation search
│   │   └── ConversationStore.swift # Thread CRUD, JSON file per conversation
│   │
│   ├── Channels/
│   │   ├── ChannelProtocol.swift  # protocol DeliveryChannel { func send(message:) async throws }
│   │   └── NotificationChannel.swift # UNUserNotificationCenter delivery
│   │
│   ├── Voice/
│   │   ├── VoiceService.swift     # SFSpeechRecognizer STT 
│   │   ├── TTSService.swift       # AVSpeechSynthesizer (system TTS, Kokoro later)
│   │   ├── WakeWordDetector.swift # SFSpeechRecognizer-based wake word 
│   │   └── VoiceSessionCoordinator.swift # Ownership model
│   │
│   └── Sensory/
│       ├── ScreenCaptureService.swift  # screencapture CLI → temp PNG
│       ├── VisionOCRService.swift      # Apple Vision OCR
│       ├── BrowserTabWatcher.swift     # AppleScript polling (Safari/Chrome/Firefox)
│       └── WorldModel.swift            # Unified sensory state → LLM context string
│
├── UI/
│   ├── Theme/
│   │   └── DockwrightTheme.swift  # Colors, typography, spacing, modifiers
│   │
│   ├── Chat/
│   │   ├── ChatView.swift         # Main chat with message list + input
│   │   ├── MessageBubble.swift    # User/assistant bubbles with markdown
│   │   ├── MessageInput.swift     # Text input + send/stop + mic button
│   │   ├── ToolCardView.swift     # Collapsible tool output cards
│   │   └── StreamingIndicator.swift # Activity pill + thinking dots
│   │
│   ├── Sidebar/
│   │   └── SidebarView.swift      # Thread list + new thread + search
│   │
│   ├── Settings/
│   │   ├── SettingsView.swift     # Tab-based settings window
│   │   └── APIKeysView.swift      # API key entry (first thing user sees)
│   │
│   ├── Scheduler/
│   │   └── SchedulerView.swift    # Cron jobs + reminders dashboard
│   │
│   └── Onboarding/
│       └── WelcomeView.swift      # API key → start chatting
│
├── Resources/
│   └── Models/                    # Wake word models (future)
│       ├── melspectrogram.onnx
│       ├── embedding_model.onnx
│       └── wake_word.onnx
│
└── Utilities/
    ├── KeychainHelper.swift       # macOS Keychain CRUD
    ├── SQLiteManager.swift        # Lightweight SQLite wrapper
    └── Logging.swift              # os.Logger wrapper
```

---

## PHASE 1 — Foundation (Chat Works)

**Goal:** User enters API key → can chat with Claude → sees streaming response with markdown.

### Files to create (in order):

#### 1.1 Utilities (build first — no dependencies)

**`Utilities/Logging.swift`**
```swift
import os
let log = Logger(subsystem: "com.Aatje.Dockwright", category: "general")
```

**`Utilities/KeychainHelper.swift`**
- Methods: `save(key:value:)`, `read(key:) -> String?`, `delete(key:)`, `exists(key:) -> Bool`
- Service name: `"com.Aatje.Dockwright"`
- Use `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`
- Add in-memory cache (Dictionary) to avoid repeated Keychain IPC
- Keys to support: `"anthropic_api_key"`, `"openai_api_key"`, `"gemini_api_key"`

**`Utilities/SQLiteManager.swift`**
- Thin wrapper around `sqlite3` C API (import SQLite3)
- Methods: `open(path:)`, `execute(sql:params:)`, `query(sql:params:) -> [[String:String]]`, `close()`
- WAL mode enabled
- Thread-safe with serial DispatchQueue

#### 1.2 Core Models

**`Core/LLM/LLMModels.swift`**
```swift
// LLMMessage — role-based message for API
struct LLMMessage: Codable, Sendable {
    let role: String  // "system", "user", "assistant", "tool"
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var images: [ImageContent]?  // base64 encoded
}

// Convenience constructors
extension LLMMessage {
    static func system(_ text: String) -> LLMMessage
    static func user(_ text: String) -> LLMMessage
    static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> LLMMessage
    static func tool(callId: String, content: String) -> LLMMessage
}

// Tool call from LLM response
struct ToolCall: Codable, Sendable {
    let id: String
    let type: String  // always "function"
    let function: ToolCallFunction
}
struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String  // JSON string
}

// Image content for vision
struct ImageContent: Codable, Sendable {
    let type: String  // "base64"
    let mediaType: String  // "image/png"
    let data: String
}

// LLM response after streaming completes
struct LLMResponse: Sendable {
    let content: String?
    let toolCalls: [ToolCall]?
    let finishReason: String?
    let inputTokens: Int
    let outputTokens: Int
    var thinkingContent: String?
}

// Stream events for UI
enum StreamChunk: Sendable {
    case textDelta(String)
    case toolStarted(String)
    case toolCompleted(name: String, preview: String, output: String)
    case toolFailed(name: String, error: String)
    case thinking(String)
    case activity(StreamActivity)
    case done(String)
}

enum StreamActivity: Sendable, Equatable {
    case thinking
    case searching(String)
    case reading(String)
    case executing(String)
    case generating
}

// Chat message for UI display
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolOutputs: [ToolOutput]
    var thinkingContent: String

    init(role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.toolOutputs = []
        self.thinkingContent = ""
    }
}

enum MessageRole: String, Codable {
    case user, assistant, system, error
}

struct ToolOutput: Identifiable, Codable {
    let id: UUID
    let toolName: String
    let output: String
    let isError: Bool
    let timestamp: Date

    init(toolName: String, output: String, isError: Bool = false) {
        self.id = UUID()
        self.toolName = toolName
        self.output = output
        self.isError = isError
        self.timestamp = Date()
    }
}

// Conversation (thread) model
struct Conversation: Identifiable, Codable {
    let id: String
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        self.id = UUID().uuidString
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
```

#### 1.3 LLM Service

**`Core/LLM/LLMService.swift`**
- Primary method: `streamChat(messages:tools:model:apiKey:onChunk:) async throws -> LLMResponse`
- Anthropic API implementation:
  - POST `https://api.anthropic.com/v1/messages`
  - Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
  - Body: `model`, `max_tokens`, `system`, `messages`, `tools`, `stream: true`
  - SSE parsing: read `data: ` lines, parse JSON, handle event types:
    - `message_start` → extract input_tokens
    - `content_block_start` → detect `tool_use` blocks (id, name)
    - `content_block_delta` → `text_delta` (append text, call onChunk(.textDelta)) or `input_json_delta` (accumulate tool args)
    - `content_block_stop` → finalize block
    - `message_delta` → extract `stop_reason`, output_tokens
  - Build ToolCall array from accumulated tool blocks
  - Return LLMResponse
- Dual timeout: 180s watchdog Task racing the stream Task
- Sanitize tool names: `^[a-zA-Z0-9_-]{1,64}$`
- JSON repair for truncated tool args: try appending `}`, `}}`

**`Core/LLM/TokenCounter.swift`**
- Track per-session: totalInputTokens, totalOutputTokens
- Cost calculation: claude-sonnet-4-20250514 input=$3/MTok, output=$15/MTok
- Method: `recordUsage(input:output:)`, `formattedCost() -> String`

#### 1.4 Tool System

**`Core/Tools/ToolRegistry.swift`**
- Protocol:
```swift
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    func execute(arguments: [String: Any]) async throws -> ToolResult
}

struct ToolResult: Sendable {
    let output: String
    let isError: Bool
    init(_ output: String, isError: Bool = false)
}
```
- Registry: `[String: any Tool]` dictionary
- Method to generate Anthropic tool definitions array
- Singleton: `ToolRegistry.shared`

**`Core/Tools/ToolExecutor.swift`**
- `executeTool(name:arguments:) async throws -> ToolResult`
- Lookup in registry, execute, catch errors, return result
- Timeout per tool: 30 seconds (shell: 120 seconds)

**`Core/Tools/ShellTool.swift`**
- Tool name: `"shell"`
- Parameters: `command` (string, required), `workingDirectory` (string, optional)
- Implementation: `Process()` with `/bin/zsh -c`
- Capture stdout + stderr via Pipe
- Return: `"Exit code: X\n\nSTDOUT:\n...\n\nSTDERR:\n..."`
- Timeout: 120 seconds
- Security: block `rm -rf /`, `sudo`, `mkfs` etc.

**`Core/Tools/FileTool.swift`**
- Tool name: `"file"`
- Actions: `read`, `write`, `list`, `search`, `exists`
- Parameters: `action` (string), `path` (string), `content` (string, for write), `pattern` (string, for search)
- `read`: FileManager read, max 100KB, return content
- `write`: FileManager write atomically
- `list`: contentsOfDirectory, formatted
- `search`: recursive glob with FileManager.enumerator
- `exists`: fileExists check

**`Core/Tools/WebSearchTool.swift`**
- Tool name: `"web_search"`
- Parameters: `query` (string)
- Use DuckDuckGo HTML search: `https://html.duckduckgo.com/html/?q=...`
- Parse results from HTML (simple regex for titles/snippets/URLs)
- Return top 5 results formatted

#### 1.5 Conversation Store

**`Core/Memory/ConversationStore.swift`**
- Storage: `~/.dockwright/conversations/` directory, one JSON file per conversation
- Index file: `~/.dockwright/conversations/index.json` (array of ConversationSummary)
- Serial DispatchQueue for all file I/O
- Methods: `save(conversation:)`, `load(id:) -> Conversation?`, `listAll() -> [ConversationSummary]`, `delete(id:)`
- ConversationSummary: id, title, updatedAt, messageCount, preview (last message truncated)

#### 1.6 App State

**`App/AppState.swift`**
```swift
@Observable
final class AppState {
    // Current conversation
    var currentConversation: Conversation = Conversation()
    var conversations: [ConversationSummary] = []

    // Chat state
    var isProcessing = false
    var streamingText = ""

    // Settings
    var selectedModel = "claude-sonnet-4-20250514"
    var showSidebar = true
    var showSettings = false

    // Services
    let llm = LLMService()
    let tools = ToolRegistry.shared
    let tokenCounter = TokenCounter()
    let conversationStore = ConversationStore()

    // API key convenience
    var hasAPIKey: Bool { KeychainHelper.read(key: "anthropic_api_key") != nil }

    // Send message — the core loop
    func sendMessage(_ text: String) async { ... }
    // This implements:
    // 1. Append user ChatMessage
    // 2. Create streaming assistant ChatMessage
    // 3. Build LLMMessage array (system + history + user)
    // 4. Call llm.streamChat with tool definitions
    // 5. Handle StreamChunks → update assistant message
    // 6. If response has toolCalls → execute each → append tool results → loop back to LLM
    // 7. On done → finalize message, save conversation

    func newConversation() { ... }
    func loadConversation(_ id: String) { ... }
    func deleteConversation(_ id: String) { ... }
}
```

#### 1.7 UI

**`UI/Theme/DockwrightTheme.swift`**
- Color palette, typography scale, spacing scale, surface colors, opacity tokens
- Modifiers: `.glassCard()`, `.hoverCard()`, `.glow()`, `.shimmer()`

**`UI/Chat/ChatView.swift`**
- ScrollViewReader + LazyVStack of MessageBubble
- Auto-scroll on new content
- Empty state with logo + suggestions

**`UI/Chat/MessageBubble.swift`**
- User: right-aligned dark pill, white text
- Assistant: left-aligned, markdown rendering, tool cards
- Custom BubbleShape with asymmetric corners
- Copy button on hover
- Streaming cursor (blinking ▎)

**`UI/Chat/MessageInput.swift`**
- TextEditor with placeholder
- Send button (white circle) / Stop button (red circle)
- Enter to send, Shift+Enter for newline
- Rounded card style with focus ring

**`UI/Chat/ToolCardView.swift`**
- Collapsible card per tool output
- Tool icon + name + preview
- Expand to see full output
- Color-coded by tool type

**`UI/Chat/StreamingIndicator.swift`**
- Activity pill: "Thinking...", "Searching...", "Executing..."
- Animated thinking dots (3 dots cycling)
- SF Symbol + label

**`UI/Sidebar/SidebarView.swift`**
- New Thread button at top
- Conversation list grouped by date (Today, Yesterday, This Week, Older)
- Click to load, swipe to delete
- Search field

**`UI/Settings/SettingsView.swift`** + **`UI/Settings/APIKeysView.swift`**
- TabView with API Keys tab
- SecureField for each provider key
- Save to Keychain button
- Status indicator (green dot if key exists)

**`UI/Onboarding/WelcomeView.swift`**
- Shows when no API key exists
- Logo + "Enter your Anthropic API key to get started"
- SecureField + Save button
- Links to get API key

#### 1.8 App Entry Point

**`App/DockwrightApp.swift`** (replace existing)
- WindowGroup with NavigationSplitView or HSplitView
- Sidebar toggle
- Settings window (Settings scene)
- Show WelcomeView if no API key

**BUILD AND TEST PHASE 1:**
```bash
cd /Users/a/Dockwright && xcodebuild -project Dockwright.xcodeproj -scheme Dockwright -configuration Debug build 2>&1 | tail -30
```
Run the app. Enter API key. Send "Hello". Verify streaming response appears.

---

## PHASE 2 — Scheduling & Reminders

**Goal:** User can say "remind me in 2 minutes to drink water" and get a macOS notification. User can create recurring cron jobs.

### Files:

**`Core/Scheduler/CronJob.swift`**
```swift
struct CronJob: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var schedule: String          // Cron expression "*/5 * * * *" OR one-shot ISO datetime
    var isOneShot: Bool           // true = reminder, false = recurring
    var action: CronAction
    var enabled: Bool
    var lastRun: Date?
    var nextRun: Date?
    var runCount: Int
    var createdAt: Date
}

enum CronAction: Codable, Sendable {
    case notification(title: String, body: String)  // macOS notification
    case tool(name: String, arguments: [String: String])  // Execute a tool
    case message(text: String)  // Send as chat message
}
```

**`Core/Scheduler/CronEngine.swift`**
- Full 5-field cron parser: minute, hour, dayOfMonth, month, dayOfWeek
- Support: `*`, ranges `1-5`, steps `*/5`, lists `1,3,5`
- `matches(date: Date) -> Bool` — check if a date matches the expression
- `nextOccurrence(after: Date) -> Date` — calculate next run time
- Natural language presets:
  - "every minute" → "* * * * *"
  - "every 5 minutes" → "*/5 * * * *"
  - "every hour" → "0 * * * *"
  - "daily at 9am" → "0 9 * * *"
  - "weekdays at 9am" → "0 9 * * 1-5"
  - "every monday at 9am" → "0 9 * * 1"

**`Core/Scheduler/CronStore.swift`**
- Persist to `~/.dockwright/cron_jobs.json`
- CRUD: add, update, remove, list, get
- Thread-safe with actor or serial queue

**`Core/Scheduler/CronRunner.swift`**
- Timer loop: check every 30 seconds
- For each enabled job: if `matches(now)` or (one-shot and `now >= nextRun`):
  - Execute action
  - Update lastRun, runCount, nextRun
  - Remove one-shot jobs after execution
- Deliver via DeliveryChannel (start with NotificationChannel)

**`Core/Scheduler/ReminderService.swift`**
- `setReminder(message:inSeconds:) -> CronJob` — create one-shot job
- Parse relative time: "in 2 minutes", "in 1 hour", "in 30 seconds"
- Parse absolute time: "at 15:30", "tomorrow 9am"
- Uses `CronStore.add()` + `CronRunner` handles execution

**`Core/Scheduler/CronTool.swift`**
- LLM tool name: `"scheduler"`
- Actions:
  - `create_reminder`: params `message` (string), `delay` (string like "2 minutes" or "1 hour")
  - `create_cron`: params `name` (string), `schedule` (string, cron or natural language), `action_type` (notification/tool/message), `action_body` (string)
  - `list_jobs`: no params, return all jobs with status
  - `delete_job`: params `id` (string)
- This is what allows the LLM to handle "over 2 minuten hoi sturen"

**`Core/Channels/ChannelProtocol.swift`**
```swift
protocol DeliveryChannel: Sendable {
    var name: String { get }
    func send(title: String, body: String) async throws
}
```

**`Core/Channels/NotificationChannel.swift`**
- UNUserNotificationCenter
- Request permission on first use
- Send notification with title + body
- Sound: default

**`UI/Scheduler/SchedulerView.swift`**
- List of all cron jobs + reminders
- Toggle enable/disable
- Delete button
- Show next run time
- "Add Reminder" quick action

**BUILD AND TEST PHASE 2:**
Run app. Chat: "remind me in 10 seconds to test". Verify notification appears after 10s.

---

## PHASE 3 — Sensory (Screen + Browser Awareness)

**Goal:** Dockwright knows what's on screen, which app is active, what browser tabs are open.

### Files:

**`Core/Sensory/ScreenCaptureService.swift`**
- Use `screencapture -x -t png <tmpPath>` via Process (works on all macOS versions)
- For macOS 15+: use `posix_spawn` with responsibility disclaim (POSIX_SPAWN_RESPONSIBLE_FLAG 0x800)
- Return path to temp PNG
- Cleanup after OCR

**`Core/Sensory/VisionOCRService.swift`**
- `recognizeText(imagePath:) async throws -> String`
- VNRecognizeTextRequest with `.accurate` level
- Language correction enabled
- Return full text joined by newlines

**`Core/Sensory/BrowserTabWatcher.swift`**
- Poll every 15 seconds
- AppleScript for Safari, Chrome, Firefox, Edge, Arc, Brave
- Extract: tab titles + URLs + active tab index
- Feed to WorldModel

**`Core/Sensory/WorldModel.swift`**
- Concurrent DispatchQueue with barrier writes
- State: frontmostApp, openApps, screenContent, browserTabs, batteryLevel, isDarkMode, currentHour
- `contextString() -> String` — formatted for LLM system prompt injection
- Methods: `updateScreenContent()`, `updateBrowserTabs()`, `updateSystemState()`
- `startAmbientLoop()` — 15-second screen capture + OCR cycle
  - Jaccard distance for change detection (threshold 0.15)
  - Skip during heavy processing

**Integration:** WorldModel.contextString() gets appended to system prompt in AppState.sendMessage()

**BUILD AND TEST PHASE 3.**

---

## PHASE 4 — Voice

**Goal:** User can talk to Dockwright. Mic button → speech-to-text → response → text-to-speech.

### Files:

**`Core/Voice/VoiceService.swift`**
- SFSpeechRecognizer + AVAudioEngine
- `startListening(onTranscription:onLevel:)` / `stopListening()`
- Silence detection: speechThreshold 0.018, silenceThreshold 0.013, silenceDuration 1.5s
- Proactive restart at 50s (Apple caps at 60s)
- Language: en-US default, configurable

**`Core/Voice/TTSService.swift`**
- Start with AVSpeechSynthesizer (system TTS — always available, no dependencies)
- `speak(text:)` / `stopSpeaking()`
- Rate: 0.52, pitch: 1.0
- Streaming TTS: buffer sentences, speak on sentence boundary
- Kokoro neural TTS can be added later as upgrade

**`Core/Voice/WakeWordDetector.swift`**
- Start with SFSpeechRecognizer-based detection 
- Listen for: "hey dockwright", "dockwright", "hey dock"
- Fuzzy matching with Levenshtein distance
- Fire callback on detection

**`Core/Voice/VoiceSessionCoordinator.swift`**
- Ownership model: only one view owns voice at a time
- `claim(owner:) -> Bool` — stops all audio, transfers ownership
- Prevents AVAudioEngine double-tap crash

**UI Integration:**
- Add mic button to MessageInput (already planned)
- Voice mode states: idle, listening, transcribing, speaking
- Animated waveform or pulsing indicator during listening

**BUILD AND TEST PHASE 4.**

---

## PHASE 5 — Polish & Multi-LLM

**Goal:** Support OpenAI, Gemini, Grok, Ollama. Memory system. Menu bar. Global hotkey. Install script.

### Files:

**LLMService extensions:**
- Add OpenAI provider (same SSE format, different URL/headers)
- Add Ollama provider (OpenAI-compatible API at localhost:11434)
- Add Gemini provider (Google AI Studio API)
- Model selector in settings + chat

**`Core/Memory/MemoryStore.swift`**
- SQLite database at `~/.dockwright/memory.db`
- Tables: `facts` (id, content, category, created_at), `episodes` (id, summary, timestamp)
- FTS5 virtual table for full-text search
- Methods: `saveFact(content:category:)`, `search(query:) -> [String]`
- LLM tool: `memory_search`, `memory_save`

**Menu bar:**
- MenuBarExtra with SF Symbol icon
- Show/hide main window
- Quick actions: new chat, toggle voice
- Status: online/offline indicator

**Global hotkey:**
- Cmd+Shift+Space to toggle window
- Use Carbon HotKey API or MASShortcut pattern

**`scripts/install.sh`**
- curl-installable script
- Downloads latest release from GitHub
- Copies to /Applications
- Sets up LaunchAgent for auto-start (optional)

**BUILD AND TEST PHASE 5.**

---

## SYSTEM PROMPT FOR DOCKWRIGHT

Use this as the default system prompt when chatting:

```
You are Dockwright, a powerful macOS AI assistant. You have access to tools that let you:
- Run shell commands on the user's Mac
- Read and write files
- Search the web
- Set reminders and schedule recurring tasks
- See what's on the user's screen
- Know which apps and browser tabs are open

Current context:
{worldModel.contextString()}

Active scheduled jobs: {cronRunner.activeJobsSummary()}

Guidelines:
- Be concise and direct
- Use tools proactively when they'd help
- For reminders/scheduling, use the scheduler tool
- When the user mentions something on screen, reference your screen awareness
- Speak Dutch if the user speaks Dutch
```

---

## REFERENCE

When implementing new components, always read existing code in the same module first to match patterns and conventions.

## PHASE 6 — Manus-Inspired Features

**Goal:** Make Dockwright feel like a real autonomous agent, not just a chatbot.

### 6.1 Plan-First Execution (Manus pattern)
When the user gives a complex task, Dockwright should:
1. **Show a plan first** — numbered steps with descriptions
2. **Execute step by step** — update each step's status (pending → running → done/failed)
3. **Allow intervention** — user can pause, skip, or modify steps mid-execution

**Implementation:**
- `TaskPlan` model: array of `PlanStep` (title, description, status, output)
- `PlanExecutor`: iterates steps, calls tools, updates UI
- `PlanView`: SwiftUI view showing step list with status indicators
- LLM generates plan as structured JSON via tool call `create_plan`

### 6.2 Live Agent Activity Panel (Manus "Computer" panel)
- Side panel (like Inspector) showing real-time agent actions
- Shows: which tool is running, what URL is being fetched, what file is being read
- Scrollable log of all actions taken
- Can replay past sessions

### 6.3 Background Task Execution
- Tasks can continue when app is in background
- macOS notification when task completes
- Uses `ProcessInfo.processInfo.performActivity()` to prevent system sleep
- Task results stored and presented when user returns

### 6.4 Multi-Step Task Decomposition
- LLM tool: `decompose_task` — breaks complex request into subtasks
- Each subtask can use different tools
- Results from earlier steps feed into later steps
- Progress bar in chat showing overall completion

---

## IMPORTANT NOTES

- **Deployment target must be changed to 14.0** in project.pbxproj (currently 26.2 which is wrong for distribution)
- **App Sandbox is OFF** — no entitlements file needed for file/network/shell access
- **Hardened Runtime is ON** — code signing works
- **No SPM packages for Phase 1-3.** Use only Apple frameworks. This avoids dependency hell.
- **Phase 4 voice** uses only Apple frameworks (Speech, AVFoundation). No external deps.
- **Do NOT use AsyncStream for SSE.** Use `URLSession.bytes(for:)` with `for try await line in bytes.lines`.
- **The user speaks Dutch sometimes.** The app should handle both English and Dutch gracefully.
